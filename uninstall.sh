#!/bin/bash
# Complete uninstall

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

echo -e "${RED}[!] This will remove Gateway Security completely${NC}"
read -p "Are you sure? (y/n): " -n 1 -r
echo

if [[ $REPLY =~ ^[Yy]$ ]]; then
    systemctl stop gateway 2>/dev/null
    systemctl disable gateway 2>/dev/null
    rm -f /etc/systemd/system/gateway.service
    rm -rf /opt/gateway
    rm -f /usr/local/bin/gateway
    rm -f /usr/local/bin/gateway-cli
    rm -f /usr/local/bin/gateway-update
    systemctl daemon-reload
    echo -e "${GREEN}[+] Gateway Security removed${NC}"
else
    echo "Cancelled."
fi