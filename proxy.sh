#!/usr/bin/env bash
# set -euo pipefail

# ─── Configuration ───────────────────────────────────────────────────────────
XRAY_DIR="${PWD}"
CONFIG_FILE="${XRAY_DIR}/config.json"
XRAY_BIN="${XRAY_DIR}/xray"
NGROK_BIN="${XRAY_DIR}/ngrok"
NGROK_YML="${XRAY_DIR}/ngrok.yml"
SUB_DIR="${XRAY_DIR}/sub"
SUB_PORT=8080

# Ports for each inbound
PORT_VLESS_R=443
PORT_VLESS_WS=8443
PORT_TROJAN=8444
PORT_VMESS=8445

NGROK_API="http://127.0.0.1:4040/api/tunnels"

# ─── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GRN='\033[0;32m'
YEL='\033[1;33m'
BLU='\033[0;34m'
CYAN='\033[0;36m'
MAG='\033[0;35m'
NC='\033[0m'

log()   { echo -e "${GRN}[proxy.sh]${NC} $1"; }
warn()  { echo -e "${YEL}[proxy.sh] WARNING${NC} $1"; }
error() { echo -e "${RED}[proxy.sh] ERROR${NC} $1"; }
info()  { echo -e "${CYAN}[proxy.sh]${NC} $1"; }

# ─── Generators ─────────────────────────────────────────────────────────────
gen_uuid() {
    local u
    u=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null || openssl rand -hex 16 2>/dev/null)
    if [[ ${#u} -ne 36 ]]; then
        u=$(python3 -c "import uuid; print(uuid.uuid4())" 2>/dev/null || cat /dev/urandom | tr -dc 'a-f0-9' | fold -w 32 | head -n 1 | sed 's/\(........\)\(....\)\(....\)\(....\)\(............\)/\1-\2-\3-\4-\5/')
    fi
    echo "$u"
}

gen_pass() { openssl rand -base64 16 | tr -d '=+/' | cut -c1-16; }
gen_shortid() { openssl rand -hex 8; }

help_msg() {
    cat <<EOF
Usage: NGROK_AUTHTOKEN=xxx ./proxy.sh

Needs: curl, unzip, python3 (auto-installed)
EOF
}

for arg in "$@"; do case "$arg" in -h|--help) help_msg; exit 0;; esac; done

# ─── OS check ────────────────────────────────────────────────────────────────
if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    [[ "$ID" != "ubuntu" && "$ID" != "debian" ]] && warn "Untested OS: $ID"
fi

# ─── Install deps ────────────────────────────────────────────────────────────
log "Checking dependencies..."
MISSING=()
for pkg in curl unzip python3; do command -v "$pkg" &>/dev/null || MISSING+=("$pkg"); done
if [[ ${#MISSING[@]} -gt 0 ]]; then
    log "Installing: ${MISSING[*]}"
    if command -v apt-get &>/dev/null; then
        sudo apt-get update -qq && sudo apt-get install -y -qq "${MISSING[@]}"
    elif command -v apk &>/dev/null; then
        sudo apk add --no-cache "${MISSING[@]}"
    elif command -v dnf &>/dev/null; then
        sudo dnf install -y "${MISSING[@]}"
    else
        error "Cannot install: ${MISSING[*]}"; exit 1
    fi
fi

# ─── Install ngrok ───────────────────────────────────────────────────────────
if command -v ngrok &>/dev/null; then
    NGROK_BIN=$(which ngrok)
    log "Using system ngrok: ${NGROK_BIN}"
elif [[ ! -x "$NGROK_BIN" ]]; then
    log "Downloading ngrok..."
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)  NGROK_ARCH="linux-amd64" ;;
        aarch64) NGROK_ARCH="linux-arm64" ;;
        armv7l)  NGROK_ARCH="linux-arm" ;;
        *)       error "Unsupported arch: $ARCH"; exit 1 ;;
    esac
    curl -L --progress-bar -o ngrok.tgz "https://bin.equinox.io/c/bNyjFmdUd9w/ngrok-v3-stable-${NGROK_ARCH}.tgz"
    tar -xzf ngrok.tgz ngrok && chmod +x ngrok && rm -f ngrok.tgz
    log "ngrok installed."
fi

[[ -z "${NGROK_AUTHTOKEN:-}" ]] && { error "Set NGROK_AUTHTOKEN"; exit 1; }

# ─── Install xray ────────────────────────────────────────────────────────────
if [[ ! -x "$XRAY_BIN" ]]; then
    log "Downloading xray-core..."
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)  XRAY_ARCH="Xray-linux-64.zip" ;;
        aarch64) XRAY_ARCH="Xray-linux-arm64-v8a.zip" ;;
        armv7l)  XRAY_ARCH="Xray-linux-arm32-v7a.zip" ;;
        *)       error "Unsupported arch: $ARCH"; exit 1 ;;
    esac
    LATEST=$(curl -sL https://api.github.com/repos/XTLS/Xray-core/releases/latest | grep "browser_download_url.*${XRAY_ARCH}" | cut -d'"' -f4)
    curl -L --progress-bar -o xray.zip "$LATEST"
    unzip -o xray.zip xray 2>/dev/null || true
    chmod +x xray && rm -f xray.zip
    log "xray-core installed."
fi

# ─── Generate credentials ────────────────────────────────────────────────────
log "Generating credentials..."
UUID_VLESS=$(gen_uuid)
UUID_WS=$(gen_uuid)
UUID_VMESS=$(gen_uuid)
TROJAN_PASS=$(gen_pass)
SHORTID=$(gen_shortid)

log "Generating Reality key pair..."
KEYS=$($XRAY_BIN x25519 2>/dev/null)
REALITY_PRIV=$(echo "$KEYS" | grep "Private key:" | awk '{print $3}')
REALITY_PUB=$(echo "$KEYS" | grep "Public key:" | awk '{print $3}')
WS_PATH="/$(echo $UUID_WS | cut -d'-' -f1)"

# ─── Write Xray unified config ─────────────────────────────────────────────
log "Writing Xray config..."
mkdir -p "$SUB_DIR"

cat > "$CONFIG_FILE" <<'XRAY_EOF'
{
  "log": {"access": "", "error": ""},
  "inbounds": [
    {
      "tag": "vless-reality",
      "port": @PORT_VLESS_R@,
      "protocol": "vless",
      "settings": {
        "clients": [{"id": "@UUID_VLESS@", "flow": "xtls-rprx-vision"}],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "www.apple.com:443",
          "xver": 0,
          "serverNames": ["www.apple.com"],
          "privateKey": "@REALITY_PRIV@",
          "shortIds": ["@SHORTID@"],
          "fingerprint": "chrome"
        }
      },
      "sniffing": {"enabled": true, "destOverride": ["http", "tls"]}
    },
    {
      "tag": "vless-ws",
      "port": @PORT_VLESS_WS@,
      "protocol": "vless",
      "settings": {"clients": [{"id": "@UUID_WS@"}], "decryption": "none"},
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": {"path": "@WS_PATH@"}
      },
      "sniffing": {"enabled": true, "destOverride": ["http", "tls"]}
    },
    {
      "tag": "trojan",
      "port": @PORT_TROJAN@,
      "protocol": "trojan",
      "settings": {"clients": [{"password": "@TROJAN_PASS@"}]},
      "streamSettings": {
        "network": "tcp",
        "security": "none"
      },
      "sniffing": {"enabled": true, "destOverride": ["http", "tls"]}
    },
    {
      "tag": "vmess",
      "port": @PORT_VMESS@,
      "protocol": "vmess",
      "settings": {"clients": [{"id": "@UUID_VMESS@", "alterId": 0}]},
      "streamSettings": {
        "network": "tcp",
        "security": "none"
      },
      "sniffing": {"enabled": true, "destOverride": ["http", "tls"]}
    }
  ],
  "outbounds": [
    {"protocol": "freedom", "settings": {}},
    {"protocol": "blackhole", "settings": {}, "tag": "blocked"}
  ]
}
XRAY_EOF

# Replace placeholders
sed -i "s|@PORT_VLESS_R@|${PORT_VLESS_R}|g; s|@PORT_VLESS_WS@|${PORT_VLESS_WS}|g; s|@PORT_TROJAN@|${PORT_TROJAN}|g; s|@PORT_VMESS@|${PORT_VMESS}|g; s|@UUID_VLESS@|${UUID_VLESS}|g; s|@UUID_WS@|${UUID_WS}|g; s|@UUID_VMESS@|${UUID_VMESS}|g; s|@TROJAN_PASS@|${TROJAN_PASS}|g; s|@REALITY_PRIV@|${REALITY_PRIV}|g; s|@SHORTID@|${SHORTID}|g; s|@WS_PATH@|${WS_PATH}|g" "$CONFIG_FILE"

# ─── Start ngrok with config file ───────────────────────────────────────────
log "Starting ngrok tunnels..."

cat > "$NGROK_YML" <<NGROK_EOF
version: "3"
agent:
  authtoken: ${NGROK_AUTHTOKEN}\nendpoints:
  - name: vless-reality
    upstream:
      url: tcp://localhost:${PORT_VLESS_R}
  - name: vless-ws
    upstream:
      url: http://localhost:${PORT_VLESS_WS}
  - name: trojan
    upstream:
      url: tcp://localhost:${PORT_TROJAN}
  - name: vmess
    upstream:
      url: tcp://localhost:${PORT_VMESS}
  - name: subscription
    upstream:
      url: http://localhost:${SUB_PORT}
NGROK_EOF

$NGROK_BIN start --all --config "${NGROK_YML}" > /dev/null 2>&1 &
NGROK_PID=$!

# ─── Wait for ngrok and collect URLs ─────────────────────────────────────────
log "Waiting for ngrok tunnels..."
NGROK_VLESS=""; NGROK_WS=""; NGROK_TROJAN=""; NGROK_VMESS=""; NGROK_SUB=""
for ((i=1; i<=40; i++)); do
    sleep 2
    DATA=$(curl -s "$NGROK_API" 2>/dev/null || true)
    [[ -z "$DATA" ]] && continue

    NGROK_VLESS=$(echo "$DATA" | grep -o '"public_url":"tcp://[^"]*"' | grep -o 'tcp://[^"]*' | sed 's/tcp://\(.*\)/\1/' | sed -n '1p')
    NGROK_WS=$(echo "$DATA" | grep -o '"public_url":"tcp://[^"]*"' | grep -o 'tcp://[^"]*' | sed 's/tcp://\(.*\)/\1/' | sed -n '2p')
    NGROK_TROJAN=$(echo "$DATA" | grep -o '"public_url":"tcp://[^"]*"' | grep -o 'tcp://[^"]*' | sed 's/tcp://\(.*\)/\1/' | sed -n '3p')
    NGROK_VMESS=$(echo "$DATA" | grep -o '"public_url":"tcp://[^"]*"' | grep -o 'tcp://[^"]*' | sed 's/tcp://\(.*\)/\1/' | sed -n '4p')
    NGROK_SUB=$(echo "$DATA" | grep -o '"public_url":"http://[^"]*"' | grep -o 'http://[^"]*' | sed -n '1p')

    # If we have the reality tunnel and a subscription, we're good
    [[ -n "$NGROK_VLESS" && -n "$NGROK_SUB" ]] && break
done

if [[ -z "$NGROK_VLESS" || -z "$NGROK_SUB" ]]; then
    error "ngrok failed to establish tunnels. Check your token."
    kill $NGROK_PID 2>/dev/null || true
    exit 1
fi

log "ngrok tunnels ready."

# ─── Parse endpoints ─────────────────────────────────────────────────────────
VL_HOST=$(echo "$NGROK_VLESS" | cut -d':' -f1)
VL_PORT=$(echo "$NGROK_VLESS" | cut -d':' -f2)
WS_HOST=$(echo "$NGROK_WS" | cut -d':' -f1)
WS_PORT=$(echo "$NGROK_WS" | cut -d':' -f2)
TR_HOST=$(echo "$NGROK_TROJAN" | cut -d':' -f1)
TR_PORT=$(echo "$NGROK_TROJAN" | cut -d':' -f2)
VM_HOST=$(echo "$NGROK_VMESS" | cut -d':' -f1)
VM_PORT=$(echo "$NGROK_VMESS" | cut -d':' -f2)

# ─── Build subscription content ──────────────────────────────────────────────
VLESS_RE_LINK="vless://${UUID_VLESS}@${VL_HOST}:${VL_PORT}?security=reality&fp=chrome&pbk=${REALITY_PUB}&sid=${SHORTID}&type=tcp&flow=xtls-rprx-vision&sni=www.apple.com&encryption=none#ngrok-vless-reality"
VLESS_WS_LINK="vless://${UUID_WS}@${WS_HOST}:${WS_PORT}?type=ws&path=${WS_PATH}&encryption=none#ngrok-vless-ws"
TROJAN_LINK="trojan://${TROJAN_PASS}@${TR_HOST}:${TR_PORT}#ngrok-trojan"

VMESS_JSON='{"v":"2","ps":"ngrok-vmess","add":"'"${VM_HOST}"'","port":"'"${VM_PORT}"'","id":"'"${UUID_VMESS}"'","aid":"0","net":"tcp","type":"none","tls":"none"}'
VMESS_LINK="vmess://$(echo -n "$VMESS_JSON" | base64 -w 0)"

# Combine all links
SUB_RAW="${VLESS_RE_LINK}
${VLESS_WS_LINK}
${TROJAN_LINK}
${VMESS_LINK}"

SUB_BASE64=$(echo -n "$SUB_RAW" | base64 -w 0)
echo "$SUB_BASE64" > "${SUB_DIR}/subscription.b64"

# ─── Start subscription HTTP server ────────────────────────────────────────────
log "Starting subscription server on port ${SUB_PORT}..."
python3 <<PYEOF &
import http.server, socketserver, os, base64

class Handler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        if self.path in ('/sub', '/sub.txt', '/subscription'):
            self.send_response(200)
            self.send_header('Content-Type', 'text/plain; charset=utf-8')
            self.send_header('Content-Disposition', 'inline; filename=subscription.txt')
            self.end_headers()
            with open('${SUB_DIR}/subscription.b64', 'rb') as f:
                self.wfile.write(f.read())
        else:
            self.send_response(200)
            self.send_header('Content-Type', 'text/html')
            self.end_headers()
            self.wfile.write(b"""<h1>Proxy Subscription Server</h1>
<p><a href=\"/sub\">Subscription (base64)</a></p>
<p>Import /sub into your V2Ray client.</p>""")

with socketserver.TCPServer(('0.0.0.0', ${SUB_PORT}), Handler) as httpd:
    httpd.serve_forever()
PYEOF
SUB_PID=$!

# ─── Final output ───────────────────────────────────────────────────────────
echo ""
echo "=========================================="
echo "  🚀 Multi-Protocol Proxy Ready!"
echo "=========================================="
echo ""
echo -e "  ${MAG}Subscription URL:${NC} ${NGROK_SUB}/sub"
echo ""
echo "------------------------------------------"
echo -e "  ${GRN}1. VLESS + Reality + XTLS (Recommended)${NC}"
echo -e "     Endpoint: ${VL_HOST}:${VL_PORT}"
echo ""
echo -e "  ${GRN}2. VLESS + WebSocket${NC}"
echo -e "     Endpoint: ${WS_HOST}:${WS_PORT} | Path: ${WS_PATH}"
echo ""
echo -e "  ${GRN}3. Trojan${NC}"
echo -e "     Endpoint: ${TR_HOST}:${TR_PORT} | Pass: ${TROJAN_PASS}"
echo ""
echo -e "  ${GRN}4. VMess${NC}"
echo -e "     Endpoint: ${VM_HOST}:${VM_PORT}"
echo ""
echo "------------------------------------------"
echo "  Links:"
echo "  ${VLESS_RE_LINK}"
echo ""
echo "=========================================="
echo ""

# ─── Cleanup trap ────────────────────────────────────────────────────────────
cleanup() {
    log "Stopping services..."
    kill $NGROK_PID 2>/dev/null || true
    kill $SUB_PID 2>/dev/null || true
    wait $NGROK_PID 2>/dev/null || true
    wait $SUB_PID 2>/dev/null || true
    log "All services stopped."
}
trap cleanup INT TERM EXIT

log "Starting Xray-core... (Ctrl-C to stop)"
$XRAY_BIN run -c "$CONFIG_FILE"