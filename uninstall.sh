#!/bin/bash
# Evilginx Complete Uninstall

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

echo -e "${RED}[!] This will remove Evilginx completely${NC}"
read -p "Are you sure? (y/n): " -n 1 -r
echo

if [[ $REPLY =~ ^[Yy]$ ]]; then
    systemctl stop gateway gateway-notify 2>/dev/null
    systemctl disable gateway gateway-notify 2>/dev/null
    rm -f /etc/systemd/system/gateway*.service
    rm -rf /opt/gateway
    rm -f /usr/local/bin/sys-svc
    systemctl daemon-reload
    echo -e "${GREEN}[+] Domain Security Gateway removed successfully${NC}"
else
    echo "Cancelled."
fi