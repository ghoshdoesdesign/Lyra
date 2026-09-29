#!/usr/bin/env bash
#
# Lyra v1: run everything on your laptop (macOS or Linux).
#
#   ./local/start.sh            # phone must be on the same Wi-Fi as the laptop
#   ./local/start.sh --tunnel   # also reachable over cellular, via a free
#                               # Cloudflare quick tunnel (URL changes each run)
#
# First run installs OpenClaw (plus Node if needed) and asks once for your
# OpenAI or Anthropic API key. Lyra only works while this script is running
# and the laptop is awake. For always-on, use deploy/setup.sh on a server.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LYRA_DIR="$HOME/.lyra"
ENV_FILE="$LYRA_DIR/lyra.env"
PORT="${LYRA_PORT:-7001}"
TUNNEL=0
[[ "${1:-}" == "--tunnel" ]] && TUNNEL=1

log() { printf '\n\033[1;35m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mError: %s\033[0m\n' "$*" >&2; exit 1; }

OS="$(uname -s)"
[[ "$OS" == "Darwin" || "$OS" == "Linux" ]] || die "supported on macOS and Linux only"
export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"

# --- uv (runs the Python server) ---------------------------------------------

if ! command -v uv >/dev/null; then
  log "Installing uv"
  curl -LsSf https://astral.sh/uv/install.sh | env UV_NO_MODIFY_PATH=1 sh
fi

# --- OpenClaw -----------------------------------------------------------------

if ! command -v openclaw >/dev/null; then
  log "Installing OpenClaw (and Node.js if needed)"
  curl -fsSL --proto '=https' --tlsv1.2 https://openclaw.ai/install.sh | bash -s -- --no-onboard
  hash -r
  command -v openclaw >/dev/null \
    || die "OpenClaw installed, but it's not on PATH yet. Open a new terminal and run this script again."
fi

if [[ ! -f "$HOME/.openclaw/openclaw.json" ]]; then
  MODEL_API_KEY="${LYRA_MODEL_API_KEY:-${OPENAI_API_KEY:-${ANTHROPIC_API_KEY:-}}}"
  if [[ -z "$MODEL_API_KEY" ]]; then
    read -rsp "Paste your OpenAI or Anthropic API key (input hidden): " MODEL_API_KEY; echo
  fi
  MODEL_API_KEY="$(printf '%s' "$MODEL_API_KEY" | tr -d '[:space:]')"
  case "$MODEL_API_KEY" in
    sk-ant-*) AUTH_ARGS=(--auth-choice apiKey --anthropic-api-key "$MODEL_API_KEY"); PROVIDER="Anthropic" ;;
    sk-*)     AUTH_ARGS=(--auth-choice openai-api-key --openai-api-key "$MODEL_API_KEY"); PROVIDER="OpenAI" ;;
    *)        die "unrecognized key format (expected sk-... for OpenAI or sk-ant-... for Anthropic)" ;;
  esac

  # The Gateway is installed as a background service (launchd on macOS,
  # systemd on Linux) and starts again when you log in.
  log "Setting up OpenClaw with your $PROVIDER key"
  openclaw onboard --non-interactive --accept-risk \
    --mode local \
    "${AUTH_ARGS[@]}" \
    --gateway-bind loopback \
    --install-daemon \
    --daemon-runtime node \
    --skip-skills
fi

# --- Lyra config --------------------------------------------------------------

mkdir -p "$LYRA_DIR"
chmod 700 "$LYRA_DIR"
if [[ ! -f "$ENV_FILE" ]]; then
  printf 'LYRA_API_TOKEN=%s\n' "$(openssl rand -hex 24)" > "$ENV_FILE"
  chmod 600 "$ENV_FILE"
fi
set -a; source "$ENV_FILE"; set +a
export LYRA_HOST=0.0.0.0 LYRA_PORT="$PORT"

# --- Addresses the phone can use ---------------------------------------------

if [[ "$OS" == "Darwin" ]]; then
  LAN_NAME="$(scutil --get LocalHostName 2>/dev/null || hostname -s).local"
  LAN_IP="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)"
else
  LAN_NAME="$(hostname).local"
  LAN_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
fi

TUNNEL_URL=""
TUNNEL_PID=""
cleanup() { [[ -n "$TUNNEL_PID" ]] && kill "$TUNNEL_PID" 2>/dev/null || true; }
trap cleanup EXIT

if (( TUNNEL )); then
  if ! command -v cloudflared >/dev/null; then
    if [[ "$OS" == "Darwin" ]] && command -v brew >/dev/null; then
      log "Installing cloudflared"
      brew install cloudflared
    else
      die "--tunnel needs cloudflared: https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/"
    fi
  fi
  log "Starting Cloudflare quick tunnel"
  TUNNEL_LOG="$LYRA_DIR/tunnel.log"
  cloudflared tunnel --no-autoupdate --url "http://127.0.0.1:$PORT" > "$TUNNEL_LOG" 2>&1 &
  TUNNEL_PID=$!
  for _ in $(seq 1 30); do
    TUNNEL_URL="$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$TUNNEL_LOG" | head -1 || true)"
    [[ -n "$TUNNEL_URL" ]] && break
    sleep 1
  done
  [[ -n "$TUNNEL_URL" ]] || die "tunnel didn't start; see $TUNNEL_LOG"
fi

cat <<EOF

────────────────────────────────────────────────────────────
 Lyra is starting on this laptop. Keep this window open.

 Server URL for the Shortcut:
EOF
if (( TUNNEL )); then
  echo "   $TUNNEL_URL        (works anywhere; changes every run)"
fi
echo "   http://$LAN_NAME:$PORT   (same Wi-Fi only)"
[[ -n "$LAN_IP" ]] && echo "   http://$LAN_IP:$PORT   (same Wi-Fi, if the name doesn't work)"
cat <<EOF

 API token : $LYRA_API_TOKEN

 Stop with Ctrl+C. Closing the lid (sleep) also stops Lyra.
────────────────────────────────────────────────────────────

EOF

# Keep the laptop from idle-sleeping while Lyra runs.
SERVER_CMD=(uv run --script "$REPO_DIR/server/lyra_server.py")
if [[ "$OS" == "Darwin" ]]; then
  caffeinate -i "${SERVER_CMD[@]}"
else
  "${SERVER_CMD[@]}"
fi
