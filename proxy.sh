#!/usr/bin/env bash
set -euo pipefail

# ─── Configuration ───────────────────────────────────────────────────────────
XRAY_DIR="${PWD}"
XRAY_CONFIG_FILE="${XRAY_DIR}/config.json"
XRAY_BIN="${XRAY_DIR}/xray"
NGINX_CONF="${XRAY_DIR}/nginx.conf"
SUB_DIR="${XRAY_DIR}/sub"
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
PORT_SS_WS=10011
PORT_SS_GRPC=10012
PORT_VMESS_GRPC=10013
PORT_VLESS_HU=10014
PORT_TROJAN_HU=10015
PORT_VMESS_HU=10016

# Cloudflare variables (must be set as env vars)
: "${CF_AUTHTOKEN:?Set CF_AUTHTOKEN}"
: "${CF_DOMAIN:?Set CF_DOMAIN (e.g. proxy.example.com)}"

# Seed for deterministic credentials — same seed = same UUIDs/passwords every run
SEED="${SEED:-$CF_AUTHTOKEN}"

# ─── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GRN='\033[0;32m'; YEL='\033[1;33m'; BLU='\033[0;34m'
CYAN='\033[0;36m'; MAG='\033[0;35m'; NC='\033[0m'
log()   { echo -e "${GRN}[proxy.sh]${NC} $1"; }
warn()  { echo -e "${YEL}[proxy.sh] WARNING${NC} $1"; }
error() { echo -e "${RED}[proxy.sh] ERROR${NC} $1"; }

help_msg() { cat <<'EOF'
Usage: CF_AUTHTOKEN=xxx CF_DOMAIN=proxy.example.com ./proxy.sh
EOF
}
for arg in "$@"; do case "$arg" in -h|--help) help_msg; exit 0;; esac; done

# ─── PID tracking + cleanup (registered early so any failure cleans up) ─────
XRAY_PID=""; CLOUDFLARED_PID=""
cleanup() {
    log "Stopping services..."
    [[ -f "${XRAY_DIR}/nginx.pid" ]] && nginx -c "${NGINX_CONF}" -s stop 2>/dev/null || true
    [[ -n "$CLOUDFLARED_PID" ]] && kill "$CLOUDFLARED_PID" 2>/dev/null || true
    [[ -n "$XRAY_PID" ]] && kill "$XRAY_PID" 2>/dev/null || true
    wait 2>/dev/null || true
    log "All services stopped."
}
trap cleanup INT TERM EXIT

# ─── Install dependencies ────────────────────────────────────────────────────
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

# ─── Install xray-core ──────────────────────────────────────────────────────
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
    [[ -z "$URL" ]] && error "Could not find xray-core download." && exit 1
    curl -L --progress-bar -o xray.zip "$URL"
    unzip -o xray.zip xray >/dev/null 2>&1 || true
    chmod +x xray && rm -f xray.zip
    log "xray-core downloaded."
fi

# ─── Install cloudflared ─────────────────────────────────────────────────────
if command -v cloudflared &>/dev/null; then
    CLOUDFLARED_BIN=$(command -v cloudflared)
    log "Using system cloudflared"
else
    log "Installing cloudflared..."
    curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main" | sudo tee /etc/apt/sources.list.d/cloudflared.list
    sudo apt-get update && sudo apt-get install cloudflared
    CLOUDFLARED_BIN=$(command -v cloudflared)
    if [[ -z "${CLOUDFLARED_BIN}" ]]; then
        # Fallback: download directly
        curl -L --progress-bar -o cloudflared "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$(uname -m)"
        chmod +x cloudflared
        CLOUDFLARED_BIN="${PWD}/cloudflared"
    fi
    log "cloudflared installed."
fi

# ─── Generate credentials ────────────────────────────────────────────────────
log "Generating credentials..."

# Derivation functions (pure shell + openssl — no files, no python, all from SEED)
hex2bin() { printf "$(echo "$1" | sed 's/\(..\)/\\x\1/g')"; }

derive_uuid() {
    local h; h=$(echo -n "${SEED}:$1" | sha256sum | head -c 32)
    printf '%s-%s-4%s-a%s-%s' "${h:0:8}" "${h:8:4}" "${h:13:3}" "${h:17:3}" "${h:20:12}"
}

derive_pass() {
    echo -n "${SEED}:$1" | openssl dgst -sha256 -binary | openssl enc -base64 -A | tr -d '=+/' | cut -c1-16
}

derive_hex() {
    echo -n "${SEED}:$1" | sha256sum | head -c "${2:-16}"
}

derive_x25519() {
    local priv_hex f_hex l_hex cf cl
    priv_hex=$(echo -n "${SEED}:$1" | sha256sum | head -c 64)
    f_hex="${priv_hex:0:2}"; l_hex="${priv_hex:62:2}"
    cf=$(printf '%02x' $((0x${f_hex} & 248)))
    cl=$(printf '%02x' $((0x${l_hex} & 127 | 64)))
    priv_hex="${cf}${priv_hex:2:60}${cl}"
    local der_hex="302e020100300506032b656e04220420${priv_hex}"
    # Extract public key DER (~44 bytes SPKI), take last 32 bytes as raw public point
    local pub_hex
    pub_hex=$(hex2bin "$der_hex" | openssl pkey -pubout -outform DER 2>/dev/null \
        | od -A n -t x1 | tr -d ' \n')
    pub_hex="${pub_hex: -64}"
    # xray expects base64url (Go's RawURLEncoding: -_ instead of +/, no padding)
    local b64url="tr '+/' '-_' | tr -d '='"
    echo "$(hex2bin "$priv_hex" | openssl enc -base64 -A | eval "$b64url")"
    echo "$(hex2bin "$pub_hex" | openssl enc -base64 -A | eval "$b64url")"
}

# Assign all credentials deterministically from SEED
UUID_VLESS=$(derive_uuid uuid/vless)
UUID_TROJAN=$(derive_uuid uuid/trojan)
UUID_VMESS=$(derive_uuid uuid/vmess)
UUID_VLESS_GRPC=$(derive_uuid uuid/vless-grpc)
UUID_TROJAN_GRPC=$(derive_uuid uuid/trojan-grpc)
UUID_SHADOWSOCKS=$(derive_uuid uuid/shadowsocks)
UUID_REALITY=$(derive_uuid uuid/reality)
TROJAN_PASS=$(derive_pass pass/trojan)
SS_PASS=$(derive_pass pass/ss)

# Reality x25519 (derive_x25519 outputs: line 1=private, line 2=public)
read -r REALITY_PRIVATE REALITY_PUBLIC <<< "$(derive_x25519 reality/keys | tr '\n' ' ')"

SHORT_ID=$(derive_hex short-id 8)
PATH_VLESS="/$(derive_hex path/vless 16)"
PATH_TROJAN="/$(derive_hex path/trojan 16)"
PATH_VMESS="/$(derive_hex path/vmess 16)"
GRPC_SERVICE_VLESS=$(derive_hex grpc/vless 16)
GRPC_SERVICE_TROJAN=$(derive_hex grpc/trojan 16)
# gRPC nginx locations must match serviceName for gRPC routing to work
PATH_VLESS_GRPC="/${GRPC_SERVICE_VLESS}"
PATH_TROJAN_GRPC="/${GRPC_SERVICE_TROJAN}"

# New external protocols (WS/gRPC through nginx/Cloudflare)
PATH_SS_WS="/$(derive_hex path/ss-ws 16)"
GRPC_SERVICE_SS=$(derive_hex grpc/ss 16)
PATH_SS_GRPC="/${GRPC_SERVICE_SS}"
GRPC_SERVICE_VMESS=$(derive_hex grpc/vmess 16)
PATH_VMESS_GRPC="/${GRPC_SERVICE_VMESS}"

# HTTPUpgrade protocols (new — simpler than WS, works through nginx/CF)
PATH_VLESS_HU="/$(derive_hex path/vless-hu 16)"
PATH_TROJAN_HU="/$(derive_hex path/trojan-hu 16)"
PATH_VMESS_HU="/$(derive_hex path/vmess-hu 16)"

# ─── Export vars for envsubst & render configs ──────────────────────────────
log "Rendering config files from templates..."
mkdir -p "$SUB_DIR" "$LOG_DIR"

export XRAY_LOG="${LOG_DIR}/xray.log" \
  XRAY_DIR LOG_DIR SUB_DIR PORT_NGINX \
  PORT_VLESS PORT_TROJAN PORT_VMESS PORT_VLESS_GRPC PORT_TROJAN_GRPC \
  PORT_SHADOWSOCKS PORT_REALITY PORT_SOCKS5 PORT_HTTP_PROXY \
  PORT_SS_WS PORT_SS_GRPC PORT_VMESS_GRPC \
  PORT_VLESS_HU PORT_TROJAN_HU PORT_VMESS_HU \
  UUID_VLESS UUID_VLESS_GRPC UUID_VMESS UUID_REALITY \
  TROJAN_PASS SS_PASS \
  PATH_VLESS PATH_TROJAN PATH_VMESS PATH_VLESS_GRPC PATH_TROJAN_GRPC \
  PATH_SS_WS PATH_SS_GRPC PATH_VMESS_GRPC \
  PATH_VLESS_HU PATH_TROJAN_HU PATH_VMESS_HU \
  GRPC_SERVICE_VLESS GRPC_SERVICE_TROJAN \
  GRPC_SERVICE_SS GRPC_SERVICE_VMESS \
  REALITY_PRIVATE REALITY_PUBLIC SHORT_ID

envsubst < templates/config.json.tmpl > "$XRAY_CONFIG_FILE"

# For nginx: only expand OUR variables, leave nginx's own vars ($http_upgrade, etc.)
NGINX_VARS='$XRAY_DIR $LOG_DIR $PORT_NGINX $SUB_DIR $PATH_VLESS $PORT_VLESS $PATH_TROJAN $PORT_TROJAN $PATH_VMESS $PORT_VMESS $PATH_VLESS_GRPC $PORT_VLESS_GRPC $PATH_TROJAN_GRPC $PORT_TROJAN_GRPC $PATH_SS_WS $PORT_SS_WS $PATH_SS_GRPC $PORT_SS_GRPC $PATH_VMESS_GRPC $PORT_VMESS_GRPC $PATH_VLESS_HU $PORT_VLESS_HU $PATH_TROJAN_HU $PORT_TROJAN_HU $PATH_VMESS_HU $PORT_VMESS_HU'
envsubst "$NGINX_VARS" < templates/nginx.conf.tmpl > "$NGINX_CONF"

# ─── Start xray first ────────────────────────────────────────────────────────
log "Starting Xray-core..."
"$XRAY_BIN" run -c "$XRAY_CONFIG_FILE" > "${LOG_DIR}/xray-output.log" 2>&1 &
XRAY_PID=$!

sleep 1
if ! kill -0 "$XRAY_PID" 2>/dev/null; then
    error "Xray failed to start. Logs:"
    tail -n 20 "${LOG_DIR}/xray-output.log" 2>/dev/null || true
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

# ─── Detect server public IP for direct connections ──────────────────────────
SERVER_IP=$(curl -s --max-time 5 https://ifconfig.me 2>/dev/null || \
            curl -s --max-time 5 https://api.ipify.org 2>/dev/null || \
            curl -s --max-time 5 https://checkip.amazonaws.com 2>/dev/null || \
            "")
if [[ -n "$SERVER_IP" ]]; then
    log "Server public IP: ${SERVER_IP}"
else
    SERVER_IP="${CF_DOMAIN}"
    warn "Could not detect public IP. Using domain for direct URLs."
fi

# ─── Build subscription URLs ──────────────────────────────────────────────────
DOMAIN="${CF_DOMAIN}"

ENC_PATH_VLESS=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "${PATH_VLESS}")
ENC_PATH_TROJAN=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "${PATH_TROJAN}")

VLESS_URL="vless://${UUID_VLESS}@${DOMAIN}:443?type=ws&security=tls&fp=chrome&packetEncoding=xudp&host=${DOMAIN}&path=${ENC_PATH_VLESS}&sni=${DOMAIN}&encryption=none#Gayroxy-🇺🇳-VLESS-WS"

TROJAN_URL="trojan://${TROJAN_PASS}@${DOMAIN}:443?type=ws&security=tls&fp=chrome&host=${DOMAIN}&path=${ENC_PATH_TROJAN}&sni=${DOMAIN}#Gayroxy-🇺🇳-Trojan-WS"

VMESS_JSON="{\"v\":\"2\",\"ps\":\"Gayroxy-🇺🇳-VMess-WS\",\"add\":\"${DOMAIN}\",\"port\":\"443\",\"id\":\"${UUID_VMESS}\",\"aid\":\"0\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"${DOMAIN}\",\"path\":\"${PATH_VMESS}\",\"tls\":\"tls\",\"sni\":\"${DOMAIN}\",\"fp\":\"chrome\"}"
VMESS_URL="vmess://$(echo -n "$VMESS_JSON" | base64 -w 0)"

VLESS_GRPC_URL="vless://${UUID_VLESS_GRPC}@${DOMAIN}:443?type=grpc&security=tls&fp=chrome&host=${DOMAIN}&serviceName=${GRPC_SERVICE_VLESS}&sni=${DOMAIN}&encryption=none#Gayroxy-🇺🇳-VLESS-gRPC"

TROJAN_GRPC_URL="trojan://${TROJAN_PASS}@${DOMAIN}:443?type=grpc&security=tls&fp=chrome&host=${DOMAIN}&serviceName=${GRPC_SERVICE_TROJAN}&sni=${DOMAIN}#Gayroxy-🇺🇳-Trojan-gRPC"

SS_BASE="$(echo -n "aes-256-gcm:${SS_PASS}" | base64 -w 0)"
SS_URL="ss://${SS_BASE}@127.0.0.1:${PORT_SHADOWSOCKS}#Gayroxy-🇺🇳-SS-Local"

REALITY_LOCAL_URL="vless://${UUID_REALITY}@127.0.0.1:${PORT_REALITY}?security=reality&flow=xtls-rprx-vision&fp=chrome&pbk=${REALITY_PUBLIC}&sid=${SHORT_ID}&type=tcp&sni=www.cloudflare.com#Gayroxy-🇺🇳-Reality-Local"

# New external protocols (WS/gRPC through Cloudflare tunnel)
SS_WS_URL="ss://$(echo -n "aes-256-gcm:${SS_PASS}" | base64 -w 0)@${DOMAIN}:443?type=ws&security=tls&path=${PATH_SS_WS}&host=${DOMAIN}#Gayroxy-🇺🇳-SS-WS"
SS_GRPC_URL="ss://$(echo -n "aes-256-gcm:${SS_PASS}" | base64 -w 0)@${DOMAIN}:443?type=grpc&security=tls&serviceName=${GRPC_SERVICE_SS}&host=${DOMAIN}#Gayroxy-🇺🇳-SS-gRPC"

VMESS_GRPC_JSON="{\"v\":\"2\",\"ps\":\"Gayroxy-🇺🇳-VMess-gRPC\",\"add\":\"${DOMAIN}\",\"port\":\"443\",\"id\":\"${UUID_VMESS}\",\"aid\":\"0\",\"net\":\"grpc\",\"type\":\"none\",\"host\":\"${DOMAIN}\",\"path\":\"${GRPC_SERVICE_VMESS}\",\"tls\":\"tls\",\"sni\":\"${DOMAIN}\",\"fp\":\"chrome\"}"
VMESS_GRPC_URL="vmess://$(echo -n "$VMESS_GRPC_JSON" | base64 -w 0)"

# HTTPUpgrade protocols (new — simpler alternative to WS, works through nginx/CF)
VLESS_HU_URL="vless://${UUID_VLESS}@${DOMAIN}:443?type=httpupgrade&security=tls&fp=chrome&host=${DOMAIN}&path=${PATH_VLESS_HU}&sni=${DOMAIN}&encryption=none#Gayroxy-🇺🇳-VLESS-HU"
TROJAN_HU_URL="trojan://${TROJAN_PASS}@${DOMAIN}:443?type=httpupgrade&security=tls&fp=chrome&host=${DOMAIN}&path=${PATH_TROJAN_HU}&sni=${DOMAIN}#Gayroxy-🇺🇳-Trojan-HU"
VMESS_HU_JSON="{\"v\":\"2\",\"ps\":\"Gayroxy-🇺🇳-VMess-HU\",\"add\":\"${DOMAIN}\",\"port\":\"443\",\"id\":\"${UUID_VMESS}\",\"aid\":\"0\",\"net\":\"httpupgrade\",\"type\":\"none\",\"host\":\"${DOMAIN}\",\"path\":\"${PATH_VMESS_HU}\",\"tls\":\"tls\",\"sni\":\"${DOMAIN}\",\"fp\":\"chrome\"}"
VMESS_HU_URL="vmess://$(echo -n "$VMESS_HU_JSON" | base64 -w 0)"

# Direct Reality (stealth — bypasses Cloudflare, connects directly to server)
REALITY_DIRECT_URL=""
if [[ -n "$SERVER_IP" ]]; then
    REALITY_DIRECT_URL="vless://${UUID_REALITY}@${SERVER_IP}:${PORT_REALITY}?security=reality&flow=xtls-rprx-vision&fp=chrome&pbk=${REALITY_PUBLIC}&sid=${SHORT_ID}&type=tcp&sni=www.cloudflare.com#Gayroxy-🇺🇳-Reality-Direct"
fi

SOCKS5_URL="socks5://127.0.0.1:${PORT_SOCKS5}#Gayroxy-🇺🇳-Socks5"
HTTP_URL="http://127.0.0.1:${PORT_HTTP_PROXY}#Gayroxy-🇺🇳-HTTP"

# ─── Build subscription file ──────────────────────────────────────────────────
SUB_CONTENT="${VLESS_URL}
${TROJAN_URL}
${VMESS_URL}
${VLESS_GRPC_URL}
${TROJAN_GRPC_URL}
${SS_URL}
${SS_WS_URL}
${SS_GRPC_URL}
${VMESS_GRPC_URL}
${VLESS_HU_URL}
${TROJAN_HU_URL}
${VMESS_HU_URL}
${REALITY_LOCAL_URL}
${REALITY_DIRECT_URL}
${SOCKS5_URL}
${HTTP_URL}"

SUB_B64=$(echo -n "$SUB_CONTENT" | base64 -w 0)
echo -n "$SUB_B64" > "${SUB_DIR}/subscription.b64"

# ─── Render HTML templates (after tunnel — we have the domain & URLs) ────────
log "Rendering HTML pages..."
envsubst '$DOMAIN' < templates/index.html.tmpl > "${SUB_DIR}/index.html"

export SUB_B64 VLESS_URL TROJAN_URL VMESS_URL VLESS_GRPC_URL TROJAN_GRPC_URL
export SS_URL SS_WS_URL SS_GRPC_URL VMESS_GRPC_URL
export VLESS_HU_URL TROJAN_HU_URL VMESS_HU_URL
export REALITY_LOCAL_URL REALITY_DIRECT_URL SOCKS5_URL HTTP_URL
export UUID_VLESS PATH_VLESS TROJAN_PASS PATH_TROJAN UUID_VMESS PATH_VMESS
export UUID_VLESS_GRPC GRPC_SERVICE_VLESS GRPC_SERVICE_TROJAN
export SS_PASS PORT_SHADOWSOCKS UUID_REALITY REALITY_PUBLIC PORT_REALITY
export PATH_SS_WS PATH_SS_GRPC PATH_VMESS_GRPC
export PATH_VLESS_HU PATH_TROJAN_HU PATH_VMESS_HU
export GRPC_SERVICE_SS GRPC_SERVICE_VMESS
export PORT_SS_WS PORT_SS_GRPC PORT_VMESS_GRPC
export PORT_VLESS_HU PORT_TROJAN_HU PORT_VMESS_HU
export PORT_SOCKS5 PORT_HTTP_PROXY
export DOMAIN SERVER_IP

envsubst < templates/panel.html.tmpl > "${SUB_DIR}/panel.html"

# ─── Final output ─────────────────────────────────────────────────────────────
echo ""
echo "=========================================="
echo "  🚀 Multi-Protocol Proxy Ready!"
echo "=========================================="
echo ""
echo -e "  ${MAG}Subscription URL:${NC} https://${DOMAIN}/sub"
echo -e "  ${MAG}Panel URL:${NC}      https://${DOMAIN}/panel"
echo ""
echo "------------------------------------------"
echo "  🌐 HTTPS Tunnel (via Cloudflare:443)"
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
echo -e "  ${GRN}Trojan + gRPC + TLS${NC}"
echo -e "     Pass:  ${TROJAN_PASS}"
echo -e "     Svc:   ${GRPC_SERVICE_TROJAN}"
echo ""
echo -e "  ${GRN}Shadowsocks + WebSocket + TLS${NC}"
echo -e "     Pass:  ${SS_PASS}"
echo -e "     Path:  ${PATH_SS_WS}"
echo ""
echo -e "  ${GRN}Shadowsocks + gRPC + TLS${NC}"
echo -e "     Pass:  ${SS_PASS}"
echo -e "     Svc:   ${GRPC_SERVICE_SS}"
echo ""
echo -e "  ${GRN}VMess + gRPC + TLS${NC}"
echo -e "     UUID:  ${UUID_VMESS}"
echo -e "     Svc:   ${GRPC_SERVICE_VMESS}"
echo ""
echo -e "  ${GRN}VLESS + HTTPUpgrade + TLS${NC}"
echo -e "     UUID:  ${UUID_VLESS}"
echo -e "     Path:  ${PATH_VLESS_HU}"
echo ""
echo -e "  ${GRN}Trojan + HTTPUpgrade + TLS${NC}"
echo -e "     Pass:  ${TROJAN_PASS}"
echo -e "     Path:  ${PATH_TROJAN_HU}"
echo ""
echo -e "  ${GRN}VMess + HTTPUpgrade + TLS${NC}"
echo -e "     UUID:  ${UUID_VMESS}"
echo -e "     Path:  ${PATH_VMESS_HU}"
echo ""
echo "------------------------------------------"
echo "  🛡️ Direct (Stealth — bypasses Cloudflare)"
echo "------------------------------------------"
if [[ -n "$REALITY_DIRECT_URL" ]]; then
echo -e "  ${GRN}REALITY (VLESS + XTLS)${NC}"
echo -e "     UUID:  ${UUID_REALITY}"
echo -e "     IP:    ${SERVER_IP}:${PORT_REALITY}"
echo -e "     Pub:   ${REALITY_PUBLIC}"
echo -e "     URL:   ${REALITY_DIRECT_URL}"
else
echo -e "  ${RED}REALITY: Could not detect server IP${NC}"
fi
echo ""
echo "------------------------------------------"
echo "  🔒 Local Only (127.0.0.1)"
echo "------------------------------------------"
echo -e "  ${GRN}Shadowsocks${NC}   127.0.0.1:${PORT_SHADOWSOCKS}"
echo -e "  ${GRN}REALITY${NC}        127.0.0.1:${PORT_REALITY}"
echo -e "  ${GRN}SOCKS5${NC}         127.0.0.1:${PORT_SOCKS5}"
echo -e "  ${GRN}HTTP Proxy${NC}     127.0.0.1:${PORT_HTTP_PROXY}"
echo ""
echo "------------------------------------------"
echo "  Quick links:"
echo "  ${VLESS_URL}"
echo ""
echo "=========================================="
echo ""

log "Running... (Ctrl-C to stop)"
wait "$XRAY_PID"
