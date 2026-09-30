#!/usr/bin/env bash
#
# Lyra v1: run everything on your laptop (macOS or Linux).
#
#   ./local/start.sh            # phone must be on the same Wi-Fi as the laptop
#   ./local/start.sh --new-key  # ask for a (new) API key even if one is set
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
NEW_KEY=0
for arg in "$@"; do
  case "$arg" in
    --tunnel)  TUNNEL=1 ;;
    --new-key) NEW_KEY=1 ;;
    *) echo "Unknown option: $arg (use --tunnel and/or --new-key)" >&2; exit 1 ;;
  esac
done

log() { printf '\n\033[1;35m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mError: %s\033[0m\n' "$*" >&2; exit 1; }

OS="$(uname -s)"
[[ "$OS" == "Darwin" || "$OS" == "Linux" ]] || die "supported on macOS and Linux only"
export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"

# --- Node.js (OpenClaw needs 24.16+ or 26.1+) -------------------------------

node_ok() {
  command -v node >/dev/null && node -e '
    const [a, b] = process.versions.node.split(".").map(Number);
    process.exit((a === 24 && b >= 16) || (a === 26 && b >= 1) || a > 26 ? 0 : 1);'
}

# If you use nvm, switch this script (not your default) to a supported Node.
NVM_SH="${NVM_DIR:-$HOME/.nvm}/nvm.sh"
if ! node_ok && [[ -s "$NVM_SH" ]]; then
  set +eu
  source "$NVM_SH"
  nvm use 26 >/dev/null 2>&1 || nvm use 24 >/dev/null 2>&1
  set -eu
  node_ok || die "OpenClaw needs Node.js 26. Run:  nvm install 26   then run this script again."
fi

# Faster `openclaw` CLI startup (Lyra runs it once per request), as
# recommended in OpenClaw's docs.
export NODE_COMPILE_CACHE="${NODE_COMPILE_CACHE:-$HOME/.cache/openclaw-compile-cache}"
mkdir -p "$NODE_COMPILE_CACHE"
export OPENCLAW_NO_RESPAWN=1

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

# Ask for a key whenever OpenClaw has no usable model credential. (A config
# file alone isn't enough: OpenClaw's installer can create one without a key.)
# `models status --check` exits 1 for missing auth, 0 when set, 2 when expiring.
auth_status=0
openclaw models status --check >/dev/null 2>&1 || auth_status=$?
if (( NEW_KEY )) || [[ ! -f "$HOME/.openclaw/openclaw.json" || $auth_status -eq 1 ]]; then
  MODEL_API_KEY=""
  if (( ! NEW_KEY )); then
    for var in LYRA_MODEL_API_KEY OPENROUTER_API_KEY OPENAI_API_KEY ANTHROPIC_API_KEY; do
      if [[ -n "${!var:-}" ]]; then
        MODEL_API_KEY="${!var}"
        echo "Using the API key from \$$var in your environment (ending …${MODEL_API_KEY: -4})."
        echo "To enter a different key instead, run: ./local/start.sh --new-key"
        break
      fi
    done
  fi
  if [[ -z "$MODEL_API_KEY" ]]; then
    read -rsp "Paste your OpenAI, Anthropic or OpenRouter API key (input hidden): " MODEL_API_KEY; echo
  fi
  MODEL_API_KEY="$(printf '%s' "$MODEL_API_KEY" | tr -d '[:space:]')"
  case "$MODEL_API_KEY" in
    sk-or-*)  AUTH_ARGS=(--auth-choice openrouter-api-key --openrouter-api-key "$MODEL_API_KEY"); PROVIDER="OpenRouter" ;;
    sk-ant-*) AUTH_ARGS=(--auth-choice apiKey --anthropic-api-key "$MODEL_API_KEY"); PROVIDER="Anthropic" ;;
    sk-*)     AUTH_ARGS=(--auth-choice openai-api-key --openai-api-key "$MODEL_API_KEY"); PROVIDER="OpenAI" ;;
    *)        die "unrecognized key format (expected sk-... for OpenAI, sk-ant-... for Anthropic, or sk-or-... for OpenRouter)" ;;
  esac

  # The Gateway is installed as a background service (launchd on macOS,
  # systemd on Linux) and starts again when you log in.
  # --skip-health: the Gateway can take longer than onboarding's own probe to
  # come up on first start; we wait for it ourselves below.
  log "Setting up OpenClaw with your $PROVIDER key"
  openclaw onboard --non-interactive --accept-risk \
    --mode local \
    "${AUTH_ARGS[@]}" \
    --gateway-bind loopback \
    --install-daemon \
    --daemon-runtime node \
    --skip-skills \
    --skip-health
fi

if (( ! NEW_KEY )) && [[ $auth_status -ne 1 && -z "${PROVIDER:-}" ]]; then
  echo "OpenClaw already has a model login configured; not asking for a key."
  echo "(See it with: openclaw models status. Replace it with: ./local/start.sh --new-key)"
fi

# --- Make sure the OpenClaw Gateway is up ------------------------------------

GATEWAY_PORT="${OPENCLAW_GATEWAY_PORT:-18789}"
gateway_up() { (echo > "/dev/tcp/127.0.0.1/$GATEWAY_PORT") 2>/dev/null; }
wait_for_gateway() {
  for _ in $(seq 1 "$1"); do gateway_up && return 0; sleep 2; done
  return 1
}

if ! gateway_up; then
  log "Waiting for the OpenClaw Gateway to start"
  if ! wait_for_gateway 30; then
    log "Gateway still not up; restarting it"
    openclaw gateway restart || true
    if ! wait_for_gateway 45; then
      GATEWAY_LOG="$HOME/Library/Logs/openclaw/gateway.log"
      if [[ -f "$GATEWAY_LOG" ]]; then
        printf '\nLast lines of %s:\n' "$GATEWAY_LOG"
        tail -n 25 "$GATEWAY_LOG"
      fi
      die "the OpenClaw Gateway isn't running. Run 'openclaw gateway status --deep' and send the output."
    fi
  fi
fi
echo "OpenClaw Gateway is running on port $GATEWAY_PORT."

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
