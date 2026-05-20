#!/bin/bash
# Evilginx Update Script

echo "[*] Updating Evilginx..."
cd /opt/evilginx
systemctl stop evilginx
rm -rf /tmp/evilginx2
git clone https://github.com/kgretzky/evilginx2.git /tmp/evilginx2
cd /tmp/evilginx2
go build -buildvcs=false -o evilginx
cp evilginx /usr/local/bin/evilginx
systemctl start evilginx
echo "[✓] Update complete! Run 'evilginx-cli' to manage"