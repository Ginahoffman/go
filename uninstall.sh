#!/bin/bash
# Complete uninstall

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

echo -e "${RED}[!] This will remove Evilginx completely${NC}"
read -p "Are you sure? (y/n): " -n 1 -r
echo

if [[ $REPLY =~ ^[Yy]$ ]]; then
    systemctl stop evilginx 2>/dev/null
    systemctl disable evilginx 2>/dev/null
    rm -f /etc/systemd/system/evilginx.service
    rm -rf /opt/evilginx
    rm -f /usr/local/bin/evilginx
    rm -f /usr/local/bin/evilginx-cli
    systemctl daemon-reload
    echo -e "${GREEN}[+] Evilginx removed successfully${NC}"
else
    echo "Cancelled."
fi