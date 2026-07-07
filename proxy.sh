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

# Ports (all on localhost, never exposed directly)
PORT_NGINX=9000
PORT_VLESS=10001
PORT_TROJAN=10002
PORT_VMESS=10003
PORT_SS=10004

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

help_msg() {
    cat <<EOF
Usage: NGROK_AUTHTOKEN=xxx NGROK_DOMAIN=my-app.ngrok-free.app ./proxy.sh

Needs: curl, unzip, python3 (auto-installed if missing)
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

# ─── Install nginx if not present ────────────────────────────────────────────
if ! command -v nginx &>/dev/null; then
    log "Installing nginx..."
    if command -v apt-get &>/dev/null; then
        sudo apt-get install -y -qq nginx
    elif command -v apk &>/dev/null; then
        sudo apk add --no-cache nginx
    else
        error "nginx cannot be installed automatically. Please install nginx."; exit 1
    fi
fi

# ─── Install ngrok ─────────────────────────────────────────────────—————
NGROK_SYSTEM=""
if command -v ngrok &>/dev/null; then
    NGROK_SYSTEM=$(command -v ngrok)
fi

if [[ -n "${NGROK_SYSTEM}" && -x "${NGROK_SYSTEM}" ]]; then
    NGROK_BIN="${NGROK_SYSTEM}"
    log "Using system ngrok: ${NGROK_BIN}"
else
    log "Installing ngrok..."

    # Prefer apt repo (most reliable)
    if command -v apt-get &>/dev/null; then
        log "Attempting apt install..."
        curl -fsSL https://ngrok-agent.s3.amazonaws.com/ngrok.asc | sudo tee /etc/apt/trusted.gpg.d/ngrok.asc >/dev/null
        echo "deb https://ngrok-agent.s3.amazonaws.com buster main" | sudo tee /etc/apt/sources.list.d/ngrok.list >/dev/null
        sudo apt-get update -qq && sudo apt-get install -y -qq ngrok 2>/dev/null && {
            NGROK_BIN=$(command -v ngrok)
            log "ngrok installed via apt."
        } || warn "apt install failed, falling back to download..."
    fi

    # Manual download
    if ! command -v ngrok &>/dev/null; then
        ARCH=$(uname -m)
        case "$ARCH" in
            x86_64)  NGROK_ARCH="linux-amd64" ;;
            aarch64) NGROK_ARCH="linux-arm64" ;;
            armv7l)  NGROK_ARCH="linux-arm" ;;
            *)       error "Unsupported arch: $ARCH"; exit 1 ;;
        esac

        NGROK_URL="https://ngrok-agent.s3.amazonaws.com/ngrok-v3-stable-${NGROK_ARCH}.tgz"
        log "Downloading ngrok..."

        # Download with proper error handling
        HTTP_CODE=$(curl -fL -w "%{http_code}" --progress-bar -o ngrok.tgz "$NGROK_URL")
        if [[ $? -ne 0 || "$HTTP_CODE" != "200" ]]; then
            error "Download failed (HTTP $HTTP_CODE). Trying fallback..."
            curl -fL -o ngrok.tgz "https://bin.equinox.io/c/bNyjFmdUd9w/ngrok-v3-stable-${NGROK_ARCH}.tgz" || {
                error "All ngrok download sources failed."
                exit 1
            }
        fi

        # Verify it's valid archive
        if ! file ngrok.tgz 2>/dev/null | grep -q "gzip"; then
            error "Downloaded file is not a valid gzip archive. Contents:"
            head -c 500 ngrok.tgz || true
            rm -f ngrok.tgz
            exit 1
        fi

        tar -xzf ngrok.tgz ngrok
        chmod +x ngrok
        rm -f ngrok.tgz
        NGROK_BIN="${PWD}/ngrok"
        log "ngrok downloaded and extracted."
    fi
fi

[[ -z "${NGROK_AUTHTOKEN:-}" ]] && { error "Set NGROK_AUTHTOKEN"; exit 1; }
[[ -z "${NGROK_DOMAIN:-}" ]]    && { error "Set NGROK_DOMAIN (e.g. my-app.ngrok-free.app)"; exit 1; }

# ─── Install xray-core ─────────────────────────────────────────────────────——
if [[ ! -x "$XRAY_BIN" ]]; then
    log "Downloading xray-core..."
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)  XRAY_ARCH="Xray-linux-64.zip" ;;
        aarch64) XRAY_ARCH="Xray-linux-arm64-v8a.zip" ;;
        armv7l)  XRAY_ARCH="Xray-linux-arm32-v7a.zip" ;;
        *)       error "Unsupported arch: $ARCH"; exit 1 ;;
    esac
    LATEST=$(curl -sL https://api.github.com/repos/XTLS/Xray-core/releases/latest | grep -oP '"browser_download_url"\s*:\s*"\K[^"]+' 2>/dev/null | grep "${XRAY_ARCH}" | head -1)
    if [[ -z "${LATEST}" ]]; then
        error "Could not find xray-core download URL."; exit 1
    fi
    curl -L --progress-bar -o xray.zip "$LATEST"
    unzip -o xray.zip xray 2>/dev/null || true
    chmod +x xray
    rm -f xray.zip
    log "xray-core installed."
fi

# ─── Generate credentials ─────────────────────────────────────────────────———
log "Generating credentials..."
UUID_VLESS=$(gen_uuid)
UUID_TROJAN=$(gen_uuid)
UUID_VMESS=$(gen_uuid)
UUID_SS=$(gen_uuid)
SS_PASS=$(gen_pass)
TROJAN_PASS=$(gen_pass)

# ─── Write Xray config ─────────────────────────────────────────────────——
log "Writing Xray config..."
mkdir -p "$SUB_DIR" "${XRAY_DIR}/logs"

CONFIG_TMP=$(mktemp)
# Template with placeholders
cat > "$CONFIG_TMP" <<'JSON'
{
  "log": {"access": "", "error": ""},
  "inbounds": [
    {
      "tag": "vless-ws",
      "listen": "127.0.0.1",
      "port": @PORT_VLESS@,
      "protocol": "vless",
      "settings": {"clients": [{"id": "@UUID_VLESS@"}], "decryption": "none"},
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": {"path": "/vless", "headers": {}}
      }
    },
    {
      "tag": "trojan-ws",
      "listen": "127.0.0.1",
      "port": @PORT_TROJAN@,
      "protocol": "trojan",
      "settings": {"clients": [{"password": "@TROJAN_PASS@"}]},
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": {"path": "/trojan"}
      }
    },
    {
      "tag": "vmess-ws",
      "listen": "127.0.0.1",
      "port": @PORT_VMESS@,
      "protocol": "vmess",
      "settings": {"clients": [{"id": "@UUID_VMESS@", "alterId": 0}]},
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": {"path": "/vmess"}
      }
    },
    {
      "tag": "shadowsocks",
      "listen": "127.0.0.1",
      "port": @PORT_SS@,
      "protocol": "shadowsocks",
      "settings": {"method": "chacha20-ietf-poly1305", "password": "@SS_PASS@", "network": "tcp,udp"},
      "streamSettings": {
        "network": "tcp",
        "security": "none"
      }
    }
  ],
  "outbounds": [
    {"protocol": "freedom", "settings": {}, "tag": "direct"},
    {"protocol": "blackhole", "settings": {}, "tag": "blocked"}
  ]
}
JSON

# Replace placeholders
sed "
s/@PORT_VLESS@/${PORT_VLESS}/g
s/@PORT_TROJAN@/${PORT_TROJAN}/g
s/@PORT_VMESS@/${PORT_VMESS}/g
s/@PORT_SS@/${PORT_SS}/g
s/@UUID_VLESS@/${UUID_VLESS}/g
s/@UUID_TROJAN@/${UUID_TROJAN}/g
s/@UUID_VMESS@/${UUID_VMESS}/g
s/@TROJAN_PASS@/${TROJAN_PASS}/g
s/@SS_PASS@/${SS_PASS}/g
" "$CONFIG_TMP" > "$CONFIG_FILE"
rm -f "$CONFIG_TMP"

# ─── Write nginx config ─────────────────────────────────────────────———
log "Writing nginx config..."

cat > "$NGINX_CONF" <<NGINX_CONF
worker_processes 1;
pid ${XRAY_DIR}/nginx.pid;
events { worker_connections 1024; }
http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    access_log /dev/null;
    error_log ${XRAY_DIR}/logs/nginx-error.log;

    server {
        listen ${PORT_NGINX};
        server_name _;

        location /sub {
            alias ${SUB_DIR}/subscription.b64;
            default_type text/plain;
            add_header Content-Disposition "inline; filename=subscription.txt";
        }

        location /vless {
            proxy_pass http://127.0.0.1:${PORT_VLESS};
            proxy_http_version 1.1;
            proxy_set_header Upgrade \\\$http_upgrade;
            proxy_set_header Connection "upgrade";
            proxy_read_timeout 86400;
        }

        location /trojan {
            proxy_pass http://127.0.0.1:${PORT_TROJAN};
            proxy_http_version 1.1;
            proxy_set_header Upgrade \\\$http_upgrade;
            proxy_set_header Connection "upgrade";
            proxy_read_timeout 86400;
        }

        location /vmess {
            proxy_pass http://127.0.0.1:${PORT_VMESS};
            proxy_http_version 1.1;
            proxy_set_header Upgrade \\\$http_upgrade;
            proxy_set_header Connection "upgrade";
            proxy_read_timeout 86400;
        }

        location / {
            root ${SUB_DIR};
            try_files \\\$uri /index.html;
        }
    }
}
NGINX_CONF

# Start nginx (not as a system service)
nginx -c "${NGINX_CONF}" -p "${XRAY_DIR}"
log "nginx running on port ${PORT_NGINX}"

# ─── Start ngrok ─────────────────────────────────────────────────—————
log "Starting ngrok tunnel to nginx on port ${PORT_NGINX}..."
NGROK_LOG="${XRAY_DIR}/logs/ngrok.log"
mkdir -p "${XRAY_DIR}/logs"

$NGROK_BIN http --authtoken "${NGROK_AUTHTOKEN}" --domain="${NGROK_DOMAIN}" ${PORT_NGINX} >"${NGROK_LOG}" 2>&1 &
NGROK_PID=$!

MAX_RETRIES=30
NGROK_URL=""
for ((i=1; i<=MAX_RETRIES; i++)); do
    sleep 2
    # Check if ngrok process died
    if ! kill -0 $NGROK_PID 2>/dev/null; then
        error "ngrok process exited unexpectedly. Last log lines:"
        tail -n 20 "${NGROK_LOG}" 2>/dev/null || true
        exit 1
    fi

    DATA=$(curl -s "$NGROK_API" 2>/dev/null || true)
    if [[ -n "$DATA" ]]; then
        NGROK_URL=$(echo "$DATA" | grep -o '"public_url":"https://[^"]*"' | head -1 | sed 's/.*"public_url":"\([^"]*\)".*/\1/')
        [[ -n "$NGROK_URL" ]] && break
    fi
done

if [[ -z "$NGROK_URL" ]]; then
    error "ngrok failed to establish tunnel."
    if [[ -f "${NGROK_LOG}" ]]; then
        error "ngrok logs:"
        cat "${NGROK_LOG}" | tail -n 20
    fi
    kill $NGROK_PID 2>/dev/null || true
    exit 1
fi

log "ngrok tunnel established: ${NGROK_URL}"

# ─── Build subscription content —————————————————————————————————————————————
VLESS_LINK="vless://${UUID_VLESS}@${NGROK_DOMAIN}:443?type=ws&security=tls&host=${NGROK_DOMAIN}&path=%2Fvless&sni=${NGROK_DOMAIN}&encryption=none#ngrok-vless-ws"
TROJAN_LINK="trojan://${TROJAN_PASS}@${NGROK_DOMAIN}:443?type=ws&security=tls&host=${NGROK_DOMAIN}&path=%2Ftrojan&sni=${NGROK_DOMAIN}#ngrok-trojan-ws"

VMESS_JSON="{\"v\":\"2\",\"ps\":\"ngrok-vmess-ws\",\"add\":\"${NGROK_DOMAIN}\",\"port\":\"443\",\"id\":\"${UUID_VMESS}\",\"aid\":\"0\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"${NGROK_DOMAIN}\",\"path\":\"/vmess\",\"tls\":\"tls\",\"sni\":\"${NGROK_DOMAIN}\"}"
VMESS_LINK="vmess://$(echo -n "$VMESS_JSON" | base64 -w 0)"

SUB_RAW="${VLESS_LINK}
${TROJAN_LINK}
${VMESS_LINK}"

SUB_BASE64=$(echo -n "$SUB_RAW" | base64 -w 0)

# Write subscription file
echo "$SUB_BASE64" > "${SUB_DIR}/subscription.b64"

# Write simple HTML page
cat > "${SUB_DIR}/index.html" <<HTML
<!DOCTYPE html>
<html><head><title>Proxy Subscription</title></head>
<body>
<h1>🚀 Proxy Subscription</h1>
<p>Import this URL into your V2Ray/NekoBox/Shadowrocket client:</p>
<code>${NGROK_URL}/sub</code>
<p>Protocols:</p>
<ul>
<li>VLESS + WebSocket + TLS</li>
<li>Trojan + WebSocket + TLS</li>
<li>VMess + WebSocket + TLS</li>
</ul>
</body></html>
HTML

# ─── Final output ─────────────────────────────────——————————————————————————
echo ""
echo "=========================================="
echo "  🚀 Multi-Protocol Proxy Ready!"
echo "=========================================="
echo ""
echo -e "  ${MAG}Subscription URL:${NC} ${NGROK_URL}/sub"
echo ""
echo "------------------------------------------"
echo -e "  ${GRN}1. VLESS + WebSocket + TLS${NC}"
echo -e "     Domain:    ${NGROK_DOMAIN}"
echo -e "     UUID:      ${UUID_VLESS}"
echo -e "     Path:      /vless"
echo ""
echo -e "  ${GRN}2. Trojan + WebSocket + TLS${NC}"
echo -e "     Domain:    ${NGROK_DOMAIN}"
echo -e "     Password:  ${TROJAN_PASS}"
echo -e "     Path:      /trojan"
echo ""
echo -e "  ${GRN}3. VMess + WebSocket + TLS${NC}"
echo -e "     Domain:    ${NGROK_DOMAIN}"
echo -e "     UUID:      ${UUID_VMESS}"
echo -e "     Path:      /vmess"
echo ""
echo "------------------------------------------"
echo "  VLESS Share Link:"
echo "  ${VLESS_LINK}"
echo ""
echo "  Trojan Share Link:"
echo "  ${TROJAN_LINK}"
echo ""
echo "  VMess Share Link:"
echo "  ${VMESS_LINK}"
echo ""
echo "=========================================="
echo ""

# ─── Cleanup trap ─——————————————————————————————————————————————————————————
cleanup() {
    log "Stopping services..."
    if [[ -f "${XRAY_DIR}/nginx.pid" ]]; then
        nginx -c "${NGINX_CONF}" -s stop 2>/dev/null || true
    fi
    kill $NGROK_PID 2>/dev/null || true
    wait $NGROK_PID 2>/dev/null || true
    log "All services stopped."
}
trap cleanup INT TERM EXIT

log "Starting Xray-core... (Ctrl-C to stop)"
$XRAY_BIN run -c "$CONFIG_FILE"