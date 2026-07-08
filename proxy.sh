#!/usr/bin/env bash
set -euo pipefail

# ─── Configuration ───────────────────────────────────────────────────────────
XRAY_DIR="${PWD}"
XRAY_CONFIG_FILE="${XRAY_DIR}/config.json"
XRAY_BIN="${XRAY_DIR}/xray"
NGINX_CONF="${XRAY_DIR}/nginx.conf"
SUB_DIR="${XRAY_DIR}/sub"
XRAY_LOG="${XRAY_DIR}/xray.log"
LOG_DIR="${XRAY_DIR}/logs"

# Ports (local only)
PORT_NGINX=9000
PORT_VLESS=10001
PORT_TROJAN=10002
PORT_VMESS=10003
PORT_VLESS_GRPC=10005
PORT_TROJAN_GRPC=10006
PORT_SHADOWSOCKS=10007
PORT_REALITY=10008
PORT_SOCKS5=10009
PORT_HTTP_PROXY=10010

# ─── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GRN='\033[0;32m'
YEL='\033[1;33m'
CYAN='\033[0;36m'
MAG='\033[0;35m'
NC='\033[0m'

log()   { echo -e "${GRN}[proxy.sh]${NC} $1"; }
warn()  { echo -e "${YEL}[proxy.sh] WARNING${NC} $1"; }
error() { echo -e "${RED}[proxy.sh] ERROR${NC} $1"; }
info()  { echo -e "${CYAN}[proxy.sh]${NC} $1"; }

help_msg() {
    cat <<'EOF'
Usage: CF_AUTHTOKEN=xxx CF_DOMAIN=proxy.example.com ./proxy.sh

  CF_AUTHTOKEN  Cloudflare Tunnel token (from the Zero Trust dashboard,
                or `cloudflared tunnel token <name>`)
  CF_DOMAIN     Public hostname already routed to that tunnel
                (e.g. proxy.example.com)
EOF
}
for arg in "$@"; do case "$arg" in -h|--help) help_msg; exit 0;; esac; done

# ─── Validate required env vars early ───────────────────────────────────────
[[ -z "${CF_AUTHTOKEN:-}" ]] && { error "Set CF_AUTHTOKEN"; help_msg; exit 1; }
[[ -z "${CF_DOMAIN:-}" ]]    && { error "Set CF_DOMAIN (e.g. proxy.example.com)"; help_msg; exit 1; }

# ─── PID tracking + cleanup (registered early so any failure cleans up) ─────
XRAY_PID=""
CLOUDFLARED_PID=""

cleanup() {
    log "Stopping services..."
    [[ -f "${XRAY_DIR}/nginx.pid" ]] && nginx -c "${NGINX_CONF}" -p "${XRAY_DIR}" -s stop 2>/dev/null || true
    [[ -n "${CLOUDFLARED_PID}" ]] && kill "${CLOUDFLARED_PID}" 2>/dev/null || true
    [[ -n "${XRAY_PID}" ]] && kill "${XRAY_PID}" 2>/dev/null || true
    [[ -n "${CLOUDFLARED_PID}" ]] && wait "${CLOUDFLARED_PID}" 2>/dev/null || true
    [[ -n "${XRAY_PID}" ]] && wait "${XRAY_PID}" 2>/dev/null || true
    log "All services stopped."
}
trap cleanup INT TERM EXIT

# ─── Install deps ────────────────────────────────────────────────────────────
log "Checking dependencies..."
MISSING=()
for pkg in curl unzip python3 nginx openssl; do command -v "$pkg" &>/dev/null || MISSING+=("$pkg"); done
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

# ─── Install cloudflared ─────────────────────────────────────────────────────
if command -v cloudflared &>/dev/null; then
    CLOUDFLARED_BIN=$(command -v cloudflared)
    log "Using system cloudflared: ${CLOUDFLARED_BIN}"
else
    log "Installing cloudflared via apt..."
    sudo mkdir -p --mode=0755 /usr/share/keyrings
    curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
    echo 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main' | sudo tee /etc/apt/sources.list.d/cloudflared.list >/dev/null
    sudo apt-get update -qq
    sudo apt-get install -y -qq cloudflared
    CLOUDFLARED_BIN=$(command -v cloudflared || true)
    if [[ -z "${CLOUDFLARED_BIN}" ]]; then
        error "cloudflared installation via apt failed. Please install manually."
        exit 1
    fi
    log "cloudflared installed via apt."
fi

# ─── Generate credentials ────────────────────────────────────────────────────
log "Generating credentials..."
UUID_VLESS=$(cat /proc/sys/kernel/random/uuid)
UUID_VMESS=$(cat /proc/sys/kernel/random/uuid)
UUID_VLESS_GRPC=$(cat /proc/sys/kernel/random/uuid)
UUID_REALITY=$(cat /proc/sys/kernel/random/uuid)
TROJAN_PASS=$(openssl rand -base64 16 | tr -d '=+/' | cut -c1-16)
SS_PASS=$(openssl rand -base64 16 | tr -d '=+/' | cut -c1-16)

REALITY_KEYS=$("$XRAY_BIN" x25519 2>/dev/null || true)
REALITY_PRIVATE=$(echo "$REALITY_KEYS" | grep 'Private' | awk '{print $3}')
REALITY_PUBLIC=$(echo "$REALITY_KEYS" | grep 'Public' | awk '{print $3}')
if [[ -z "$REALITY_PRIVATE" || -z "$REALITY_PUBLIC" ]]; then
    warn "xray x25519 keygen failed; Reality inbound will not be cryptographically valid."
    REALITY_PRIVATE=$(cat /proc/sys/kernel/random/uuid)
    REALITY_PUBLIC=$(cat /proc/sys/kernel/random/uuid)
fi

gen_id() { cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen | tr -d '-'; }

PATH_VLESS="/$(gen_id)"
PATH_TROJAN="/$(gen_id)"
PATH_VMESS="/$(gen_id)"
PATH_VLESS_GRPC="/vless-grpc-$(gen_id)"
PATH_TROJAN_GRPC="/trojan-grpc-$(gen_id)"
GRPC_SERVICE_VLESS="$(gen_id)"
GRPC_SERVICE_TROJAN="$(gen_id)"

# ─── Write xray config ─────────────────────────────────────────────────────
log "Writing Xray config..."
mkdir -p "$SUB_DIR" "$LOG_DIR"

cat > "$XRAY_CONFIG_FILE" <<JSON
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
    },
    {
      "tag": "vless-grpc",
      "listen": "127.0.0.1",
      "port": ${PORT_VLESS_GRPC},
      "protocol": "vless",
      "settings": {"clients": [{"id": "${UUID_VLESS_GRPC}"}], "decryption": "none"},
      "streamSettings": {
        "network": "grpc",
        "security": "none",
        "grpcSettings": {"serviceName": "${GRPC_SERVICE_VLESS}"}
      }
    },
    {
      "tag": "trojan-grpc",
      "listen": "127.0.0.1",
      "port": ${PORT_TROJAN_GRPC},
      "protocol": "trojan",
      "settings": {"clients": [{"password": "${TROJAN_PASS}"}]},
      "streamSettings": {
        "network": "grpc",
        "security": "none",
        "grpcSettings": {"serviceName": "${GRPC_SERVICE_TROJAN}"}
      }
    },
    {
      "tag": "shadowsocks",
      "listen": "127.0.0.1",
      "port": ${PORT_SHADOWSOCKS},
      "protocol": "shadowsocks",
      "settings": {"method": "aes-256-gcm", "password": "${SS_PASS}"}
    },
    {
      "tag": "reality",
      "listen": "127.0.0.1",
      "port": ${PORT_REALITY},
      "protocol": "vless",
      "settings": {"clients": [{"id": "${UUID_REALITY}"}], "decryption": "none"},
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "www.cloudflare.com:443",
          "serverNames": ["www.cloudflare.com"],
          "privateKey": "${REALITY_PRIVATE}",
          "publicKey": "${REALITY_PUBLIC}",
          "shortIds": ["$(openssl rand -hex 4)"]
        }
      }
    },
    {
      "tag": "socks5",
      "listen": "127.0.0.1",
      "port": ${PORT_SOCKS5},
      "protocol": "socks",
      "settings": {"auth": "noauth"}
    },
    {
      "tag": "http-proxy",
      "listen": "127.0.0.1",
      "port": ${PORT_HTTP_PROXY},
      "protocol": "http",
      "settings": {}
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
    error_log ${LOG_DIR}/nginx-error.log;

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

        # gRPC locations: grpc_pass only (mixing with proxy_pass is invalid/ambiguous).
        # Requires nginx built with the gRPC module and HTTP/2 negotiated by the
        # upstream tunnel; if traffic arrives as plain HTTP/1.1 through cloudflared
        # these will not work end-to-end without additional h2c handling.
        location ${PATH_VLESS_GRPC} {
            grpc_pass grpc://127.0.0.1:${PORT_VLESS_GRPC};
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
        }

        location ${PATH_TROJAN_GRPC} {
            grpc_pass grpc://127.0.0.1:${PORT_TROJAN_GRPC};
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
        }

        location /panel {
            root ${SUB_DIR};
            try_files \$uri /panel.html;
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
$XRAY_BIN run -c "$XRAY_CONFIG_FILE" > "${LOG_DIR}/xray-output.log" 2>&1 &
XRAY_PID=$!

sleep 1
if ! kill -0 "$XRAY_PID" 2>/dev/null; then
    error "Xray failed to start. Logs:"
    cat "${LOG_DIR}/xray-output.log" 2>/dev/null | tail -n 20 || true
    exit 1
fi
log "Xray running (PID: $XRAY_PID)"

# ─── Start nginx ─────────────────────────────────────────────────────────────
if ! nginx -t -c "${NGINX_CONF}" > /dev/null 2>&1; then
    error "nginx config test failed:"
    nginx -t -c "${NGINX_CONF}"
    exit 1
fi

nginx -c "${NGINX_CONF}" -p "${XRAY_DIR}"
log "nginx running on port ${PORT_NGINX}"

curl -sI "http://127.0.0.1:${PORT_NGINX}/" > /dev/null 2>&1 && log "nginx responds locally ✔" || {
    error "nginx not responding locally. Check ${LOG_DIR}/nginx-error.log"
    exit 1
}

# ─── Start Cloudflare Tunnel ────────────────────────────────────────────────
CLOUDFLARED_LOG="${LOG_DIR}/cloudflared.log"
log "Starting Cloudflare tunnel..."

"$CLOUDFLARED_BIN" tunnel --no-autoupdate run --token "${CF_AUTHTOKEN}" --url "http://127.0.0.1:${PORT_NGINX}" >"${CLOUDFLARED_LOG}" 2>&1 &
CLOUDFLARED_PID=$!

MAX_RETRIES=30
TUNNEL_UP=0
for ((i=1; i<=MAX_RETRIES; i++)); do
    sleep 2
    if ! kill -0 "$CLOUDFLARED_PID" 2>/dev/null; then
        error "cloudflared died. Log:"
        tail -n 20 "${CLOUDFLARED_LOG}" 2>/dev/null || true
        exit 1
    fi
    if grep -q "Registered tunnel connection" "${CLOUDFLARED_LOG}" 2>/dev/null; then
        TUNNEL_UP=1
        break
    fi
done

if [[ "$TUNNEL_UP" -ne 1 ]]; then
    error "Cloudflare tunnel failed to establish within timeout."
    cat "${CLOUDFLARED_LOG}" | tail -n 30
    exit 1
fi

log "Cloudflare tunnel established for domain: ${CF_DOMAIN}"

# ─── Build subscription ─────────────────────────────────────────────────────
DOMAIN="${CF_DOMAIN}"

ENC_PATH_VLESS=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "${PATH_VLESS}")
ENC_PATH_TROJAN=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "${PATH_TROJAN}")

VLESS_URL="vless://${UUID_VLESS}@${DOMAIN}:443?type=ws&security=tls&fp=chrome&packetEncoding=xudp&host=${DOMAIN}&path=${ENC_PATH_VLESS}&sni=${DOMAIN}&encryption=none#cf-vless-ws"

TROJAN_URL="trojan://${TROJAN_PASS}@${DOMAIN}:443?type=ws&security=tls&fp=chrome&host=${DOMAIN}&path=${ENC_PATH_TROJAN}&sni=${DOMAIN}#cf-trojan-ws"

VMESS_JSON="{\"v\":\"2\",\"ps\":\"cf-vmess-ws\",\"add\":\"${DOMAIN}\",\"port\":\"443\",\"id\":\"${UUID_VMESS}\",\"aid\":\"0\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"${DOMAIN}\",\"path\":\"${PATH_VMESS}\",\"tls\":\"tls\",\"sni\":\"${DOMAIN}\",\"fp\":\"chrome\"}"
VMESS_URL="vmess://$(echo -n "$VMESS_JSON" | base64 -w 0)"

VLESS_GRPC_URL="vless://${UUID_VLESS_GRPC}@${DOMAIN}:443?type=grpc&security=tls&fp=chrome&host=${DOMAIN}&serviceName=${GRPC_SERVICE_VLESS}&sni=${DOMAIN}&encryption=none#cf-vless-grpc"

TROJAN_GRPC_URL="trojan://${TROJAN_PASS}@${DOMAIN}:443?type=grpc&security=tls&fp=chrome&host=${DOMAIN}&serviceName=${GRPC_SERVICE_TROJAN}&sni=${DOMAIN}#cf-trojan-grpc"

SS_BASE="$(echo -n "aes-256-gcm:${SS_PASS}" | base64 -w 0)"
SS_URL="ss://${SS_BASE}@127.0.0.1:${PORT_SHADOWSOCKS}#ss-local"

REALITY_URL="vless://${UUID_REALITY}@127.0.0.1:${PORT_REALITY}?security=reality&flow=xtls-rprx-vision&fp=chrome&pbk=${REALITY_PUBLIC}&sid=$(echo -n "${REALITY_PRIVATE}" | base64 -w 0 | head -c 8)&type=tcp&sni=www.cloudflare.com#reality-local"

SOCKS5_URL="socks5://127.0.0.1:${PORT_SOCKS5}#socks5-local"
HTTP_URL="http://127.0.0.1:${PORT_HTTP_PROXY}#http-proxy-local"

SUB_CONTENT="${VLESS_URL}
${TROJAN_URL}
${VMESS_URL}
${VLESS_GRPC_URL}
${TROJAN_GRPC_URL}
${SS_URL}
${REALITY_URL}
${SOCKS5_URL}
${HTTP_URL}"

echo -n "$SUB_CONTENT" | base64 -w 0 > "${SUB_DIR}/subscription.b64"

# ─── HTML landing page & panel ───────────────────────────────────────────—
cat > "${SUB_DIR}/index.html" <<HTML
<!DOCTYPE html>
<html><head><title>Proxy Subscription</title></head>
<body>
<h1>🚀 Proxy Subscription</h1>
<p>Subscription URL: <code>https://${DOMAIN}/sub</code></p>
<ul>
<li>VLESS + WebSocket + TLS</li>
<li>Trojan + WebSocket + TLS</li>
<li>VMess + WebSocket + TLS</li>
<li>VLESS + gRPC + TLS</li>
<li>Trojan + gRPC + TLS</li>
<li>Shadowsocks (local)</li>
<li>Reality (local)</li>
<li>Socks5 (local)</li>
<li>HTTP Proxy (local)</li>
</ul>
</body></html>
HTML

# ─── Final output ───────────────────────────────────────────────────────────—
echo ""
echo "=========================================="
echo "  🚀 Multi-Protocol Proxy Ready!"
echo "=========================================="
echo ""
echo -e "  ${MAG}Subscription URL:${NC} https://${DOMAIN}/sub"
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
echo -e "  ${GRN}VLESS + gRPC + TLS${NC}"
echo -e "     UUID:  ${UUID_VLESS_GRPC}"
echo -e "     Svc:   ${GRPC_SERVICE_VLESS}"
echo ""
echo -e "  ${GRN}Shadowsocks (local only)${NC}   127.0.0.1:${PORT_SHADOWSOCKS}"
echo -e "  ${GRN}Reality (local only)${NC}       127.0.0.1:${PORT_REALITY}"
echo -e "  ${GRN}SOCKS5 (local only)${NC}        127.0.0.1:${PORT_SOCKS5}"
echo -e "  ${GRN}HTTP proxy (local only)${NC}    127.0.0.1:${PORT_HTTP_PROXY}"
echo ""
echo "------------------------------------------"
echo "  Full VLESS link:"
echo "  ${VLESS_URL}"
echo ""
echo "=========================================="
echo ""

log "Running... (Ctrl-C to stop)"
wait "$XRAY_PID"
