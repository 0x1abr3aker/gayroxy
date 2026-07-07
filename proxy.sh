#!/usr/bin/env bash
set -euo pipefail

# ─── Configuration ───────────────────────────────────────────────────────────
XRAY_DIR="${PWD}"
CONFIG_FILE="${XRAY_DIR}/config.json"
XRAY_BIN="${XRAY_DIR}/xray"
NGROK_BIN="${XRAY_DIR}/ngrok"
NGINX_CONF="${XRAY_DIR}/nginx.conf"
SUB_DIR="${XRAY_DIR}/sub"
NGROK_API="http://127.0.0.1:4040/api/tunnels"
XRAY_LOG="${XRAY_DIR}/xray.log"

# Ports (local only)
PORT_NGINX=9000
PORT_VLESS=10001
PORT_TROJAN=10002
PORT_VMESS=10003

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

help_msg() {
    cat <<'EOF'
Usage: NGROK_AUTHTOKEN=xxx NGROK_DOMAIN=my-app.ngrok-free.app ./proxy.sh
EOF
}
for arg in "$@"; do case "$arg" in -h|--help) help_msg; exit 0;; esac; done

# ─── Install deps ────────────────────────────────────────────────────────────
log "Checking dependencies..."
MISSING=()
for pkg in curl unzip python3 nginx; do command -v "$pkg" &>/dev/null || MISSING+=("$pkg"); done
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

# ─── Install xray-core ─────────────────────────────────────────────────────
if [[ ! -x "$XRAY_BIN" ]]; then
    log "Downloading xray-core..."
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)  XRAY_ZIP="Xray-linux-64.zip" ;;
        aarch64) XRAY_ZIP="Xray-linux-arm64-v8a.zip" ;;
        armv7l)  XRAY_ZIP="Xray-linux-arm32-v7a.zip" ;;
        *)       error "Unsupported arch: $ARCH"; exit 1 ;;
    esac
    URL=$(curl -sL https://api.github.com/repos/XTLS/Xray-core/releases/latest \
        | grep -oP '"browser_download_url"\s*:\s*"\K[^"]+' | grep "$XRAY_ZIP" | head -1)
    if [[ -z "$URL" ]]; then error "Could not find xray-core download."; exit 1; fi
    curl -L --progress-bar -o xray.zip "$URL"
    unzip -o xray.zip xray >/dev/null 2>&1 || true
    chmod +x xray && rm -f xray.zip
    log "xray-core downloaded."
fi

# ─── Install ngrok ─────────────────────────────────────────────────────────
if command -v ngrok &>/dev/null; then
    NGROK_BIN=$(command -v ngrok)
    log "Using system ngrok: ${NGROK_BIN}"
else
    log "Installing ngrok via apt..."
    curl -fsSL "https://ngrok-agent.s3.amazonaws.com/ngrok.asc" | sudo tee /etc/apt/trusted.gpg.d/ngrok.asc >/dev/null
    echo "deb https://ngrok-agent.s3.amazonaws.com bookworm main" | sudo tee /etc/apt/sources.list.d/ngrok.list
    sudo apt-get update -qq
    sudo apt-get install -y ngrok
    NGROK_BIN=$(command -v ngrok)
    if [[ -z "${NGROK_BIN}" ]]; then
        error "ngrok installation via apt failed. Please install manually."
        exit 1
    fi
    log "ngrok installed via apt."
fi

[[ -z "${NGROK_AUTHTOKEN:-}" ]] && { error "Set NGROK_AUTHTOKEN"; exit 1; }
[[ -z "${NGROK_DOMAIN:-}" ]]    && { error "Set NGROK_DOMAIN (e.g. my-app.ngrok-free.app)"; exit 1; }

# ─── Generate credentials ────────────────────────────────────────────────────
log "Generating credentials..."
UUID_VLESS=$(cat /proc/sys/kernel/random/uuid)
UUID_TROJAN=$(cat /proc/sys/kernel/random/uuid)
UUID_VMESS=$(cat /proc/sys/kernel/random/uuid)
TROJAN_PASS=$(openssl rand -base64 16 | tr -d '=+/' | cut -c1-16)

# Unique random paths (like the working single-config)
PATH_VLESS="/$(cat /proc/sys/kernel/random/uuid || uuidgen | tr -d '-')"
PATH_TROJAN="/$(cat /proc/sys/kernel/random/uuid || uuidgen | tr -d '-')"
PATH_VMESS="/$(cat /proc/sys/kernel/random/uuid || uuidgen | tr -d '-')"

# ─── Write xray config ─────────────────────────────────────────────────────
log "Writing Xray config..."
mkdir -p "$SUB_DIR" "${XRAY_DIR}/logs"

cat > "$CONFIG_FILE" <<JSON
{
  "log": {"access": "${XRAY_LOG}", "error": "${XRAY_LOG}"},
  "inbounds": [
    {
      "tag": "vless-ws",
      "listen": "127.0.0.1",
      "port": ${PORT_VLESS},
      "protocol": "vless",
      "settings": {"clients": [{"id": "${UUID_VLESS}"}], "decryption": "none"},
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": {"path": "${PATH_VLESS}"}
      }
    },
    {
      "tag": "trojan-ws",
      "listen": "127.0.0.1",
      "port": ${PORT_TROJAN},
      "protocol": "trojan",
      "settings": {"clients": [{"password": "${TROJAN_PASS}"}]},
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": {"path": "${PATH_TROJAN}"}
      }
    },
    {
      "tag": "vmess-ws",
      "listen": "127.0.0.1",
      "port": ${PORT_VMESS},
      "protocol": "vmess",
      "settings": {"clients": [{"id": "${UUID_VMESS}", "alterId": 0}]},
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": {"path": "${PATH_VMESS}"}
      }
    }
  ],
  "outbounds": [
    {"protocol": "freedom", "settings": {}, "tag": "direct"}
  ]
}
JSON

# ─── Write nginx config ────────────────────────────────────────────────────
log "Writing nginx config..."

cat > "$NGINX_CONF" <<EOF
worker_processes 1;
pid ${XRAY_DIR}/nginx.pid;
events { worker_connections 1024; }
http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    access_log /dev/null;
    error_log ${XRAY_DIR}/logs/nginx-error.log;

    map \$http_upgrade \$connection_upgrade {
        default upgrade;
        ''      close;
    }

    server {
        listen ${PORT_NGINX};
        server_name _;

        location /sub {
            alias ${SUB_DIR}/subscription.b64;
            default_type text/plain;
        }

        location ${PATH_VLESS} {
            proxy_pass http://127.0.0.1:${PORT_VLESS};
            proxy_http_version 1.1;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection \$connection_upgrade;
            proxy_read_timeout 86400;
            proxy_connect_timeout 86400;
        }

        location ${PATH_TROJAN} {
            proxy_pass http://127.0.0.1:${PORT_TROJAN};
            proxy_http_version 1.1;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection \$connection_upgrade;
            proxy_read_timeout 86400;
            proxy_connect_timeout 86400;
        }

        location ${PATH_VMESS} {
            proxy_pass http://127.0.0.1:${PORT_VMESS};
            proxy_http_version 1.1;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection \$connection_upgrade;
            proxy_read_timeout 86400;
            proxy_connect_timeout 86400;
        }

        location / {
            root ${SUB_DIR};
            try_files \$uri /index.html;
        }
    }
}
EOF

# ─── Start xray first ────────────────────────────────────────────────────────
log "Starting Xray-core..."
$XRAY_BIN run -c "$CONFIG_FILE" > "${XRAY_DIR}/logs/xray-output.log" 2>&1 &
XRAY_PID=$!

sleep 1
if ! kill -0 $XRAY_PID 2>/dev/null; then
    error "Xray failed to start. Logs:"
    cat "${XRAY_DIR}/logs/xray-output.log" 2>/dev/null | tail -n 20 || true
    exit 1
fi
log "Xray running (PID: $XRAY_PID)"

# ─── Start nginx ─────────────────────────────────────────────────────────────
if ! nginx -t -c "${NGINX_CONF}" > /dev/null 2>&1; then
    error "nginx config test failed:"
    nginx -t -c "${NGINX_CONF}"
    kill $XRAY_PID 2>/dev/null || true
    exit 1
fi

nginx -c "${NGINX_CONF}" -p "${XRAY_DIR}"
log "nginx running on port ${PORT_NGINX}"

# Quick local test
curl -sI http://127.0.0.1:${PORT_NGINX}/ > /dev/null 2>&1 && log "nginx responds locally ✔" || {
    error "nginx not responding locally. Check ${XRAY_DIR}/logs/nginx-error.log"
    kill $XRAY_PID 2>/dev/null || true
    exit 1
}

# ─── Start ngrok ─────────────────────────────────────────────────────────────
NGROK_LOG="${XRAY_DIR}/logs/ngrok.log"
log "Starting ngrok tunnel..."
$NGROK_BIN http --authtoken "${NGROK_AUTHTOKEN}" --domain="${NGROK_DOMAIN}" ${PORT_NGINX} >"${NGROK_LOG}" 2>&1 &
NGROK_PID=$!

MAX_RETRIES=30
NGROK_URL=""
for ((i=1; i<=MAX_RETRIES; i++)); do
    sleep 2
    if ! kill -0 $NGROK_PID 2>/dev/null; then
        error "ngrok died. Log:"
        tail -n 20 "${NGROK_LOG}" 2>/dev/null || true
        kill $XRAY_PID 2>/dev/null || true
        exit 1
    fi

    DATA=$(curl -s --max-time 2 "$NGROK_API" 2>/dev/null || true)
    if [[ -n "$DATA" ]]; then
        NGROK_URL=$(echo "$DATA" | grep -o '"public_url":"https://[^"]*"' | head -1 | sed 's/.*"public_url":"\([^"]*\)".*/\1/')
        [[ -n "$NGROK_URL" ]] && break
    fi
done

if [[ -z "$NGROK_URL" ]]; then
    error "ngrok tunnel failed."
    cat "${NGROK_LOG}" | tail -n 30
    kill $XRAY_PID 2>/dev/null || true
    exit 1
fi

log "ngrok tunnel: ${NGROK_URL}"

# ─── Build subscription ─────────────────────────────────────────────────────—
DOMAIN="${NGROK_DOMAIN}"

VLESS_URL="vless://${UUID_VLESS}@${DOMAIN}:443?type=ws&security=tls&fp=chrome&packetEncoding=xudp&host=${DOMAIN}&path=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${PATH_VLESS}'))")&sni=${DOMAIN}&encryption=none#ngrok-vless-ws"

TROJAN_URL="trojan://${TROJAN_PASS}@${DOMAIN}:443?type=ws&security=tls&fp=chrome&host=${DOMAIN}&path=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${PATH_TROJAN}'))")&sni=${DOMAIN}#ngrok-trojan-ws"

VMESS_JSON="{\"v\":\"2\",\"ps\":\"ngrok-vmess-ws\",\"add\":\"${DOMAIN}\",\"port\":\"443\",\"id\":\"${UUID_VMESS}\",\"aid\":\"0\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"${DOMAIN}\",\"path\":\"${PATH_VMESS}\",\"tls\":\"tls\",\"sni\":\"${DOMAIN}\",\"fp\":\"chrome\"}"
VMESS_URL="vmess://$(echo -n "$VMESS_JSON" | base64 -w 0)"

SUB_CONTENT="${VLESS_URL}
${TROJAN_URL}
${VMESS_URL}"

echo -n "$SUB_CONTENT" | base64 -w 0 > "${SUB_DIR}/subscription.b64"

# ─── HTML landing page ──────────────────────────────────────────────────────
cat > "${SUB_DIR}/index.html" <<HTML
<!DOCTYPE html>
<html><head><title>Proxy Subscription</title></head>
<body>
<h1>🚀 Proxy Subscription</h1>
<p>Subscription URL: <code>${NGROK_URL}/sub</code></p>
<ul>
<li>VLESS + WebSocket + TLS</li>
<li>Trojan + WebSocket + TLS</li>
<li>VMess + WebSocket + TLS</li>
</ul>
</body></html>
HTML

# ─── Final output ───────────────────────────────────────────────────────────—
echo ""
echo "=========================================="
echo "  🚀 Multi-Protocol Proxy Ready!"
echo "=========================================="
echo ""
echo -e "  ${MAG}Subscription URL:${NC} ${NGROK_URL}/sub"
echo ""
echo "------------------------------------------"
echo -e "  ${GRN}VLESS + WebSocket + TLS${NC}"
echo -e "     UUID:  ${UUID_VLESS}"
echo -e "     Path:  ${PATH_VLESS}"
echo ""
echo -e "  ${GRN}Trojan + WebSocket + TLS${NC}"
echo -e "     Pass:  ${TROJAN_PASS}"
echo -e "     Path:  ${PATH_TROJAN}"
echo ""
echo -e "  ${GRN}VMess + WebSocket + TLS${NC}"
echo -e "     UUID:  ${UUID_VMESS}"
echo -e "     Path:  ${PATH_VMESS}"
echo ""
echo "------------------------------------------"
echo "  ${VLESS_URL}"
echo ""
echo "=========================================="
echo ""

# ─── Cleanup ─────────────────────────────────────────────────────────────────
cleanup() {
    log "Stopping services..."
    [[ -f "${XRAY_DIR}/nginx.pid" ]] && nginx -c "${NGINX_CONF}" -s stop 2>/dev/null || true
    kill $NGROK_PID $XRAY_PID 2>/dev/null || true
    wait $NGROK_PID 2>/dev/null || true
    wait $XRAY_PID 2>/dev/null || true
    log "All services stopped."
}
trap cleanup INT TERM EXIT

log "Running... (Ctrl-C to stop)"
wait $XRAY_PID