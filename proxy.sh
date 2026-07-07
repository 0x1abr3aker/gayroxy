#!/usr/bin/env bash
set -euo pipefail

# Configuration
XRAY_DIR="${PWD}"
CONFIG_FILE="${XRAY_DIR}/config.json"
XRAY_BIN="${XRAY_DIR}/xray"
NGROK_BIN="${XRAY_DIR}/ngrok"
LOCAL_PORT="${PROXY_PORT:-$(shuf -i 10000-65535 -n 1)}"
# Reality destination: a high-traffic site supporting TLS 1.3 and HTTP/2
REALITY_DEST="www.apple.com:443"
SERVER_NAME="www.apple.com"
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
  PROXY_PORT        Optional. Local port for xray to bind (default: random 10000-65535).

Options:
  -h, --help        Show this help message.
  --status          Show how to set up ngrok authtoken.

Examples:
  NGROK_AUTHTOKEN=2KPyZ... ./proxy.sh
  NGROK_AUTHTOKEN=2KPyZ... PROXY_PORT=443 ./proxy.sh
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

# 6. Generate UUID and Reality keys
UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen || openssl rand -hex 16)
if [[ ${#UUID} -ne 36 ]]; then
    UUID=$(python3 -c "import uuid; print(uuid.uuid4())" 2>/dev/null || cat /dev/urandom | tr -dc 'a-f0-9' | fold -w 32 | head -n 1 | sed 's/\(........\)\(....\)\(....\)\(....\)\(............\)/\1-\2-\3-\4-\5/')
fi

log "Generating Reality key pair..."
KEYS=$($XRAY_BIN x25519 2>/dev/null)
if [[ -z "$KEYS" ]]; then
    error "Failed to generate x25519 keys with xray binary."
    exit 1
fi
PRIVATE_KEY=$(echo "$KEYS" | grep "Private key:" | awk '{print $3}')
PUBLIC_KEY=$(echo "$KEYS" | grep "Public key:" | awk '{print $3}')

if [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]]; then
    error "Failed to parse x25519 keys."
    exit 1
fi

# 7. Write Xray config
cat > "$CONFIG_FILE" <<EOF
{
  "log": { "access": "", "error": "" },
  "inbounds": [
    {
      "port": ${LOCAL_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${REALITY_DEST}",
          "xver": 0,
          "serverNames": [
            "${SERVER_NAME}"
          ],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": [""],
          "fingerprint": "chrome"
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

# 8. Start ngrok TCP tunnel in background
log "Starting ngrok TCP tunnel on port $LOCAL_PORT..."
$NGROK_BIN tcp $LOCAL_PORT &
NGROK_PID=$!

# 9. Wait for ngrok to establish tunnel and extract public URL
MAX_RETRIES=30
NGROK_URL=""
for ((i=1; i<=MAX_RETRIES; i++)); do
    sleep 1
    NGROK_DATA=$(curl -s "$NGROK_API" 2>/dev/null || true)
    if [[ -n "$NGROK_DATA" ]]; then
        NGROK_URL=$(echo "$NGROK_DATA" | grep -o '"public_url":"tcp://[^"]*"' | head -n1 | sed 's/.*"tcp://\(.*\)".*/\1/')
        if [[ -n "$NGROK_URL" ]]; then
            break
        fi
    fi
done

if [[ -z "$NGROK_URL" ]]; then
    error "ngrok failed to establish a tunnel. Check your NGROK_AUTHTOKEN and internet connection."
    kill $NGROK_PID 2>/dev/null || true
    exit 1
fi

log "ngrok tunnel established: ${NGROK_URL}"

# Extract host and port from ngrok URL
NGROK_HOST=$(echo "$NGROK_URL" | cut -d':' -f1)
NGROK_PORT=$(echo "$NGROK_URL" | cut -d':' -f2)

# 10. Print client config
VLESS_LINK="vless://${UUID}@${NGROK_HOST}:${NGROK_PORT}?security=reality&fp=chrome&pbk=${PUBLIC_KEY}&sid=&type=tcp&flow=xtls-rprx-vision&sni=${SERVER_NAME}&encryption=none#ngrok-xray"

echo ""
echo "=========================================="
echo "  🚀 Xray Proxy Server Ready!"
echo "=========================================="
echo ""
echo -e "  ${BLU}Public Endpoint:${NC}   ${NGROK_URL}"
echo -e "  ${BLU}Server Name (SNI):${NC} ${SERVER_NAME}"
echo -e "  ${BLU}UUID:${NC}             ${UUID}"
echo -e "  ${BLU}Flow:${NC}             xtls-rprx-vision"
echo -e "  ${BLU}Security:${NC}         reality"
echo -e "  ${BLU}Fingerprint:${NC}      chrome"
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
echo "    \"net\": \"tcp\","
echo "    \"type\": \"none\","
echo "    \"host\": \"\","
echo "    \"path\": \"\","
echo "    \"tls\": \"reality\","
echo "    \"sni\": \"${SERVER_NAME}\","
echo "    \"fp\": \"chrome\","
echo "    \"pbk\": \"${PUBLIC_KEY}\","
echo "    \"sid\": \"\","
echo "    \"spx\": \"\","
echo "    \"flow\": \"xtls-rprx-vision\""
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
