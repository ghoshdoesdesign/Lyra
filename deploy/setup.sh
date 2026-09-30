#!/usr/bin/env bash
#
# Lyra server setup: installs OpenClaw + the Lyra voice bridge on a fresh
# Ubuntu 24.04 VPS so Lyra runs 24/7, independent of your laptop.
#
# Usage (as root, from a checkout of this repo on the VPS):
#   ./deploy/setup.sh
# On first run it asks for one API key (OpenAI "sk-..." or Anthropic
# "sk-ant-...") and detects which provider it belongs to. You can also pass
# it non-interactively: LYRA_MODEL_API_KEY=sk-... ./deploy/setup.sh
#
# Optional:
#   LYRA_DOMAIN=lyra.example.com   use your own domain (DNS A record → this VPS);
#                                  defaults to <public-ip>.sslip.io
#
# Safe to re-run: it upgrades OpenClaw, redeploys the server, and keeps the
# existing API token and OpenClaw state.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LYRA_USER="lyra"
INSTALL_DIR="/opt/lyra"
ENV_FILE="/etc/lyra/lyra.env"

log() { printf '\n\033[1;35m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mError: %s\033[0m\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "run as root (sudo ./deploy/setup.sh)"
grep -qi ubuntu /etc/os-release || die "this script targets Ubuntu 24.04"

# --- Inputs -------------------------------------------------------------------

LYRA_HOME="/home/$LYRA_USER"

if [[ -z "${LYRA_DOMAIN:-}" ]]; then
  PUBLIC_IP="$(curl -4fsS --max-time 10 https://api.ipify.org || hostname -I | awk '{print $1}')"
  [[ -n "$PUBLIC_IP" ]] || die "could not detect public IP; set LYRA_DOMAIN"
  LYRA_DOMAIN="${PUBLIC_IP//./-}.sslip.io"
fi

# --- Base packages ------------------------------------------------------------

log "Installing base packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y curl ca-certificates gnupg ufw debian-keyring debian-archive-keyring apt-transport-https

# Small VPSes need swap for OpenClaw's Node process.
if [[ ! -f /swapfile ]] && (( $(awk '/MemTotal/ {print $2}' /proc/meminfo) < 3000000 )); then
  log "Adding 2 GB swap"
  fallocate -l 2G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

# --- Node.js 24 + OpenClaw ----------------------------------------------------

if ! node --version 2>/dev/null | grep -q '^v24\.'; then
  log "Installing Node.js 24"
  curl -fsSL https://deb.nodesource.com/setup_24.x | bash -
  apt-get install -y nodejs
fi

log "Installing/upgrading OpenClaw"
npm install -g openclaw@latest
openclaw --version

# --- uv (runs the Python server) ---------------------------------------------

if ! command -v uv >/dev/null; then
  log "Installing uv"
  curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin UV_NO_MODIFY_PATH=1 sh
fi

# --- Service user -------------------------------------------------------------

if ! id "$LYRA_USER" >/dev/null 2>&1; then
  log "Creating user $LYRA_USER"
  useradd --create-home --shell /bin/bash "$LYRA_USER"
fi
# Keep the user's systemd services (the OpenClaw Gateway) running without a login.
loginctl enable-linger "$LYRA_USER"
LYRA_UID="$(id -u "$LYRA_USER")"
systemctl start "user@${LYRA_UID}.service"

as_lyra() {
  runuser -u "$LYRA_USER" -- env \
    HOME="$LYRA_HOME" \
    XDG_RUNTIME_DIR="/run/user/$LYRA_UID" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$LYRA_UID/bus" \
    "$@"
}

# --- OpenClaw onboarding + Gateway daemon ------------------------------------

ask_for_key() {
  MODEL_API_KEY="${LYRA_MODEL_API_KEY:-${OPENAI_API_KEY:-${ANTHROPIC_API_KEY:-}}}"
  if [[ -z "$MODEL_API_KEY" ]]; then
    read -rsp "Paste your OpenAI or Anthropic API key (input hidden): " MODEL_API_KEY; echo
  fi
  MODEL_API_KEY="$(printf '%s' "$MODEL_API_KEY" | tr -d '[:space:]')"
  [[ -n "$MODEL_API_KEY" ]] || die "an API key is required for first-time setup"
  case "$MODEL_API_KEY" in
    sk-ant-*) AUTH_ARGS=(--auth-choice apiKey --anthropic-api-key "$MODEL_API_KEY"); PROVIDER="Anthropic" ;;
    sk-*)     AUTH_ARGS=(--auth-choice openai-api-key --openai-api-key "$MODEL_API_KEY"); PROVIDER="OpenAI" ;;
    *)        die "unrecognized key format (expected sk-... for OpenAI or sk-ant-... for Anthropic)" ;;
  esac
}

# Onboard whenever OpenClaw has no usable model credential (not just when the
# config is missing). `models status --check`: 1 = missing auth, 0 = ok.
auth_status=0
as_lyra openclaw models status --check >/dev/null 2>&1 || auth_status=$?
if [[ ! -f "$LYRA_HOME/.openclaw/openclaw.json" || $auth_status -eq 1 ]]; then
  ask_for_key
  log "Onboarding OpenClaw with your $PROVIDER key (Gateway on loopback, systemd user service)"
  as_lyra openclaw onboard --non-interactive --accept-risk \
    --mode local \
    "${AUTH_ARGS[@]}" \
    --gateway-bind loopback \
    --install-daemon \
    --daemon-runtime node \
    --skip-skills \
    --skip-health
else
  log "OpenClaw already onboarded; restarting Gateway"
  as_lyra systemctl --user restart openclaw-gateway.service || true
fi

# The Gateway can take a while on first start; wait (and retry once).
gateway_up() { (echo > /dev/tcp/127.0.0.1/18789) 2>/dev/null; }
wait_for_gateway() { for _ in $(seq 1 "$1"); do gateway_up && return 0; sleep 2; done; return 1; }
if ! wait_for_gateway 30; then
  log "Gateway not up yet; restarting it"
  as_lyra openclaw gateway restart || true
  wait_for_gateway 45 || die "OpenClaw Gateway isn't running; check: sudo -iu $LYRA_USER journalctl --user -u openclaw-gateway -n 50"
fi

# --- Lyra server --------------------------------------------------------------

log "Deploying Lyra server to $INSTALL_DIR"
install -d -o root -g root -m 755 "$INSTALL_DIR"
install -o root -g root -m 755 "$REPO_DIR/server/lyra_server.py" "$INSTALL_DIR/lyra_server.py"
install -o root -g root -m 755 "$REPO_DIR/server/test_client.py" "$INSTALL_DIR/test_client.py"

install -d -o root -g "$LYRA_USER" -m 750 "$(dirname "$ENV_FILE")"
if [[ ! -f "$ENV_FILE" ]]; then
  cat > "$ENV_FILE" <<EOF
LYRA_API_TOKEN=$(openssl rand -hex 24)
LYRA_HOST=127.0.0.1
LYRA_PORT=7001
LYRA_AGENT=main
EOF
fi
chown root:"$LYRA_USER" "$ENV_FILE"
chmod 640 "$ENV_FILE"

install -o root -g root -m 644 "$REPO_DIR/deploy/lyra.service" /etc/systemd/system/lyra.service
systemctl daemon-reload
# Resolve Python deps once so the first request isn't slow.
as_lyra uv sync --script "$INSTALL_DIR/lyra_server.py" >/dev/null 2>&1 || true
systemctl enable lyra.service
systemctl restart lyra.service

# --- HTTPS (Caddy) ------------------------------------------------------------

if ! command -v caddy >/dev/null; then
  log "Installing Caddy"
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
    | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
    > /etc/apt/sources.list.d/caddy-stable.list
  apt-get update -y
  apt-get install -y caddy
fi

log "Configuring HTTPS for $LYRA_DOMAIN"
sed "s/{{LYRA_DOMAIN}}/$LYRA_DOMAIN/" "$REPO_DIR/deploy/Caddyfile" > /etc/caddy/Caddyfile
systemctl enable caddy
systemctl reload caddy || systemctl restart caddy

# --- Firewall -----------------------------------------------------------------

log "Configuring firewall (SSH, HTTP, HTTPS only)"
ufw allow OpenSSH
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

# --- Verify -------------------------------------------------------------------

log "Waiting for Lyra to come up"
for _ in $(seq 1 30); do
  curl -fsS http://127.0.0.1:7001/health >/dev/null 2>&1 && break
  sleep 2
done
curl -fsS http://127.0.0.1:7001/health >/dev/null || die "Lyra server not responding; check: journalctl -u lyra -n 50"

HTTPS_OK=0
for _ in $(seq 1 30); do
  curl -fsS "https://$LYRA_DOMAIN/health" >/dev/null 2>&1 && { HTTPS_OK=1; break; }
  sleep 3
done

TOKEN="$(grep '^LYRA_API_TOKEN=' "$ENV_FILE" | cut -d= -f2)"

cat <<EOF

────────────────────────────────────────────────────────────
 Lyra is running (and will keep running after reboots).

 Server URL : https://$LYRA_DOMAIN
 API token  : $TOKEN

 Put both into the "It's Showtime" Shortcut (see SHORTCUT.md).
EOF
if (( ! HTTPS_OK )); then
  cat <<EOF

 ⚠ HTTPS isn't answering yet. Make sure your cloud provider's
   firewall allows inbound TCP 80 and 443, then check:
   journalctl -u caddy -n 50
EOF
fi
cat <<EOF

 Test from anywhere:
   LYRA_URL=https://$LYRA_DOMAIN LYRA_API_TOKEN=$TOKEN \\
     uv run $INSTALL_DIR/test_client.py
────────────────────────────────────────────────────────────
EOF
