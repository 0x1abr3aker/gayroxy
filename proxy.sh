#!/usr/bin/env bash
# set -euo pipefail

# Configuration
XRAY_DIR="${PWD}"
CONFIG_FILE="${XRAY_DIR}/config.json"
XRAY_BIN="${XRAY_DIR}/xray"
NGROK_BIN="${XRAY_DIR}/ngrok"
LOCAL_PORT="${PROXY_PORT:-$(shuf -i 10000-65535 -n 1)}"
WS_PATH="${WS_PATH:-/$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null || echo ws$RANDOM)}"
NGROK_API="http://127.0.0.1:4040/api/tunnels"

# Colors
RED='\033[0;31m'
GRN='\033[0;32m'
YEL='\033[1;33m'
BLU='\033[0;34m'
NC='\033[0m'

log() { echo -e "${GRN}[proxy.sh]${NC} $1"; }
warn() { echo -e "${YEL}[proxy.sh] WARNING${NC} $1"; }
error() { echo -e "${RED}[proxy.sh] ERROR${NC} $1"; }

help_msg() {
    cat <<EOF
Usage: ./proxy.sh [options]

Environment Variables:
  NGROK_AUTHTOKEN   Required. Your ngrok authtoken.
  NGROK_DOMAIN      Required. Your free static ngrok domain (e.g. your-name.ngrok-free.app).
                    Reserve one at: https://dashboard.ngrok.com/domains
  PROXY_PORT        Optional. Local port for xray to bind (default: random 10000-65535).
  WS_PATH           Optional. WebSocket path (default: random UUID-based path).

Examples:
  NGROK_AUTHTOKEN=2KPyZ... NGROK_DOMAIN=your-name.ngrok-free.app ./proxy.sh
  NGROK_AUTHTOKEN=2KPyZ... NGROK_DOMAIN=your-name.ngrok-free.app PROXY_PORT=8080 ./proxy.sh

Note:
  This script uses an ngrok HTTP tunnel with your free static domain, since
  free ngrok accounts require card verification for raw TCP tunnels. Because
  HTTP tunnels terminate TLS at ngrok's edge, Xray is configured with
  VLESS + WebSocket (no Reality/XTLS) instead of VLESS + Reality.
EOF
}

# 1. Parse args
for arg in "$@"; do
    case "$arg" in
        -h|--help)
            help_msg
            exit 0
            ;;
        --status)
            echo "To get your ngrok authtoken:"
            echo "  1. Sign up/login at https://dashboard.ngrok.com"
            echo "  2. Go to 'Your Authtoken' section"
            echo "  3. Copy the token and run:"
            echo "     export NGROK_AUTHTOKEN=<your_token>"
            echo "     ./proxy.sh"
            exit 0
            ;;
    esac
done

# 2. Check OS
if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    if [[ "$ID" != "ubuntu" && "$ID" != "debian" ]]; then
        warn "Unsupported OS: $ID. This script is tested on Ubuntu/Debian. Proceeding anyway..."
    fi
else
    warn "Cannot detect OS. Proceeding anyway..."
fi

# 3. Install system dependencies
log "Checking system dependencies..."
MISSING_PKGS=()
for pkg in curl unzip; do
    if ! command -v "$pkg" &> /dev/null; then
        MISSING_PKGS+=("$pkg")
    fi
done

if [[ ${#MISSING_PKGS[@]} -gt 0 ]]; then
    log "Installing missing packages: ${MISSING_PKGS[*]}"
    if command -v apt-get &> /dev/null; then
        sudo apt-get update -qq
        sudo apt-get install -y -qq "${MISSING_PKGS[@]}"
    elif command -v apk &> /dev/null; then
        sudo apk add --no-cache "${MISSING_PKGS[@]}"
    elif command -v yum &> /dev/null; then
        sudo yum install -y "${MISSING_PKGS[@]}"
    elif command -v dnf &> /dev/null; then
        sudo dnf install -y "${MISSING_PKGS[@]}"
    else
        error "Cannot install missing packages automatically. Please install: ${MISSING_PKGS[*]}"
        exit 1
    fi
    log "Dependencies installed."
else
    log "All system dependencies are present."
fi

# 4. Check for ngrok (system or local), installing via apt if possible
NGROK_SYSTEM=$(which ngrok 2>/dev/null || echo "")
if [[ -n "$NGROK_SYSTEM" && -x "$NGROK_SYSTEM" ]]; then
    NGROK_BIN="$NGROK_SYSTEM"
    log "Using system ngrok: $NGROK_BIN"
elif command -v apt-get &> /dev/null; then
    log "Installing ngrok via apt..."
    if ! command -v gpg &> /dev/null; then
        sudo apt-get update -qq
        sudo apt-get install -y -qq gnupg
    fi
    curl -sSL https://ngrok-agent.s3.amazonaws.com/ngrok.asc \
        | sudo tee /etc/apt/trusted.gpg.d/ngrok.asc >/dev/null
    echo "deb https://ngrok-agent.s3.amazonaws.com buster main" \
        | sudo tee /etc/apt/sources.list.d/ngrok.list >/dev/null
    sudo apt-get update -qq
    sudo apt-get install -y -qq ngrok

    NGROK_SYSTEM=$(which ngrok 2>/dev/null || echo "")
    if [[ -n "$NGROK_SYSTEM" && -x "$NGROK_SYSTEM" ]]; then
        NGROK_BIN="$NGROK_SYSTEM"
        log "ngrok installed via apt: $NGROK_BIN"
    else
        warn "apt install of ngrok did not produce a usable binary. Falling back to direct download."
        NGROK_SYSTEM=""
    fi
fi

if [[ -z "$NGROK_SYSTEM" && ! -x "$NGROK_BIN" ]]; then
    log "Falling back to direct ngrok binary download..."
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)  NGROK_ARCH="linux-amd64" ;;
        aarch64) NGROK_ARCH="linux-arm64" ;;
        armv7l)  NGROK_ARCH="linux-arm" ;;
        *)       error "Unsupported architecture for ngrok: $ARCH"; exit 1 ;;
    esac
    NGROK_URL="https://bin.equinox.io/c/bNyjFmdUd9w/ngrok-v3-stable-${NGROK_ARCH}.tgz"
    curl -L --progress-bar -o ngrok.tgz "$NGROK_URL"
    tar -xzf ngrok.tgz ngrok
    chmod +x ngrok
    rm -f ngrok.tgz
    log "ngrok downloaded and extracted to $NGROK_BIN."
elif [[ -z "$NGROK_SYSTEM" ]]; then
    log "ngrok already exists locally at $NGROK_BIN."
fi

# Verify ngrok authtoken is set
if [[ -z "${NGROK_AUTHTOKEN:-}" ]]; then
    error "NGROK_AUTHTOKEN is not set."
    echo "Run: export NGROK_AUTHTOKEN=<your_token> then re-run this script."
    echo "Get your token at: https://dashboard.ngrok.com/get-started/your-authtoken"
    exit 1
fi

# Verify a static ngrok domain is set (required for the free-tier HTTP tunnel)
if [[ -z "${NGROK_DOMAIN:-}" ]]; then
    error "NGROK_DOMAIN is not set."
    echo "Reserve your free static domain here: https://dashboard.ngrok.com/domains"
    echo "Then run: export NGROK_DOMAIN=<your-domain>.ngrok-free.app"
    exit 1
fi

# 5. Download Xray-core if not present
if [[ ! -x "$XRAY_BIN" ]]; then
    log "Downloading xray-core..."
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)  XRAY_ARCH="Xray-linux-64.zip" ;;
        aarch64) XRAY_ARCH="Xray-linux-arm64-v8a.zip" ;;
        armv7l)  XRAY_ARCH="Xray-linux-arm32-v7a.zip" ;;
        *)       error "Unsupported architecture: $ARCH"; exit 1 ;;
    esac
    RELEASE_JSON=$(curl -sL https://api.github.com/repos/XTLS/Xray-core/releases/latest)
    if echo "$RELEASE_JSON" | grep -q '"message": *"API rate limit exceeded'; then
        error "GitHub API rate limit exceeded while looking up xray-core releases."
        echo "Set GITHUB_TOKEN (or GH_TOKEN) in the environment to authenticate and raise the limit, then retry."
        exit 1
    fi
    LATEST_URL=$(echo "$RELEASE_JSON" \
        | grep "\"browser_download_url\":" \
        | grep "${XRAY_ARCH}\"" \
        | head -n1 \
        | cut -d '"' -f 4)
    if [[ -z "$LATEST_URL" ]]; then
        error "Failed to find xray-core download URL for $ARCH"
        exit 1
    fi
    curl -L --progress-bar -o xray.zip "$LATEST_URL"
    unzip -o xray.zip xray 2>/dev/null || true
    chmod +x xray
    rm -f xray.zip
    log "xray-core downloaded."
else
    log "xray-core already exists."
fi

# 6. Generate UUID (no Reality keys needed for WS transport)
UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen || openssl rand -hex 16)
if [[ ${#UUID} -ne 36 ]]; then
    UUID=$(python3 -c "import uuid; print(uuid.uuid4())" 2>/dev/null || cat /dev/urandom | tr -dc 'a-f0-9' | fold -w 32 | head -n 1 | sed 's/\(........\)\(....\)\(....\)\(....\)\(............\)/\1-\2-\3-\4-\5/')
fi

# 7. Write Xray config (VLESS + WebSocket; TLS is terminated by ngrok's edge,
#    so Xray's own security stays "none" here)
cat > "$CONFIG_FILE" <<EOF
{
  "log": { "access": "", "error": "" },
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": ${LOCAL_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": {
          "path": "${WS_PATH}"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {}
    }
  ]
}
EOF

log "Config written to $CONFIG_FILE"
log "Local port: $LOCAL_PORT"
log "UUID: $UUID"
log "WS path: $WS_PATH"

# 8. Start ngrok HTTP tunnel with the static domain in background
log "Starting ngrok HTTP tunnel on port $LOCAL_PORT with domain $NGROK_DOMAIN..."
$NGROK_BIN http --domain="$NGROK_DOMAIN" $LOCAL_PORT &
NGROK_PID=$!

# 9. Wait for ngrok to establish tunnel and extract public URL
MAX_RETRIES=30
NGROK_URL=""
for ((i=1; i<=MAX_RETRIES; i++)); do
    sleep 1
    NGROK_DATA=$(curl -s "$NGROK_API" 2>/dev/null || true)
    if [[ -n "$NGROK_DATA" ]]; then
        NGROK_URL=$(echo "$NGROK_DATA" | grep -o '"public_url":"https://[^"]*"' | head -n1 | sed 's/.*"public_url":"\(.*\)"/\1/')
        if [[ -n "$NGROK_URL" ]]; then
            break
        fi
    fi
done

if [[ -z "$NGROK_URL" ]]; then
    error "ngrok failed to establish a tunnel. Check your NGROK_AUTHTOKEN, NGROK_DOMAIN, and internet connection."
    kill $NGROK_PID 2>/dev/null || true
    exit 1
fi

log "ngrok tunnel established: ${NGROK_URL}"

# Host is the static domain; ngrok serves HTTPS on 443
NGROK_HOST="$NGROK_DOMAIN"
NGROK_PORT=443
WS_PATH_ENC=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "${WS_PATH}" 2>/dev/null || echo "${WS_PATH}")

# 10. Print client config
VLESS_LINK="vless://${UUID}@${NGROK_HOST}:${NGROK_PORT}?security=tls&type=ws&host=${NGROK_HOST}&path=${WS_PATH_ENC}&encryption=none#ngrok-xray"

echo ""
echo "=========================================="
echo "  🚀 Xray Proxy Server Ready!"
echo "=========================================="
echo ""
echo -e "  ${BLU}Public Endpoint:${NC}   ${NGROK_URL}"
echo -e "  ${BLU}UUID:${NC}             ${UUID}"
echo -e "  ${BLU}Network:${NC}          ws"
echo -e "  ${BLU}WS Path:${NC}          ${WS_PATH}"
echo -e "  ${BLU}Security:${NC}         tls (terminated at ngrok edge)"
echo ""
echo "------------------------------------------"
echo "  VLESS Share Link:"
echo "  ${VLESS_LINK}"
echo ""
echo "  Or use this JSON for manual setup:"
echo "  {"
echo "    \"v\": \"2\","
echo "    \"ps\": \"ngrok-xray\","
echo "    \"add\": \"${NGROK_HOST}\","
echo "    \"port\": \"${NGROK_PORT}\","
echo "    \"id\": \"${UUID}\","
echo "    \"aid\": \"0\","
echo "    \"net\": \"ws\","
echo "    \"type\": \"none\","
echo "    \"host\": \"${NGROK_HOST}\","
echo "    \"path\": \"${WS_PATH}\","
echo "    \"tls\": \"tls\""
echo "  }"
echo ""
echo "=========================================="
echo ""

# 11. Start Xray in foreground, cleaning up ngrok on exit
cleanup() {
    log "Stopping ngrok (PID: $NGROK_PID)..."
    kill $NGROK_PID 2>/dev/null || true
    wait $NGROK_PID 2>/dev/null || true
    log "Cleanup complete."
}
trap cleanup INT TERM EXIT

log "Starting xray-core... (Press Ctrl-C to stop)"
$XRAY_BIN run -c "$CONFIG_FILE"
