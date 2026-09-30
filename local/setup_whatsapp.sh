#!/usr/bin/env bash
#
# Connect Lyra to WhatsApp through OpenClaw's built-in WhatsApp channel, so it
# texts you each background task's result and the conversation transcript.
# Works in both modes:
#
#   Laptop (macOS/Linux):   ./local/setup_whatsapp.sh
#   Cloud server (as root): sudo ./local/setup_whatsapp.sh
#
# You'll scan a QR code with WhatsApp on your phone (Settings → Linked Devices),
# like logging in to WhatsApp Web. Restart Lyra afterwards.

set -euo pipefail

log() { printf '\n\033[1;35m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mError: %s\033[0m\n' "$*" >&2; exit 1; }

# --- Laptop or server? --------------------------------------------------------

SERVER_ENV="/etc/lyra/lyra.env"
if [[ $EUID -eq 0 && -f "$SERVER_ENV" ]] && id lyra >/dev/null 2>&1; then
  MODE="server"
  ENV_FILE="$SERVER_ENV"
  LYRA_UID="$(id -u lyra)"
  oc() {
    runuser -u lyra -- env HOME=/home/lyra \
      XDG_RUNTIME_DIR="/run/user/$LYRA_UID" \
      DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$LYRA_UID/bus" \
      openclaw "$@"
  }
else
  MODE="laptop"
  ENV_FILE="$HOME/.lyra/lyra.env"
  # Use a supported Node for the openclaw CLI (same logic as local/start.sh).
  NVM_SH="${NVM_DIR:-$HOME/.nvm}/nvm.sh"
  if [[ -s "$NVM_SH" ]]; then
    set +eu; source "$NVM_SH"; nvm use 26 >/dev/null 2>&1 || nvm use 24 >/dev/null 2>&1; set -eu
  fi
  command -v openclaw >/dev/null || die "openclaw not found; run ./local/start.sh first"
  oc() { openclaw "$@"; }
fi
echo "Setting up WhatsApp for Lyra ($MODE mode)."

# --- Who gets the texts ------------------------------------------------------

NUMBER="${1:-}"
if [[ -z "$NUMBER" ]]; then
  read -rp "Your WhatsApp number to receive texts, with country code (e.g. +14155551234): " NUMBER
fi
NUMBER="$(printf '%s' "$NUMBER" | tr -d '[:space:]()-')"
[[ "$NUMBER" =~ ^\+[0-9]{7,15}$ ]] || die "use international format, e.g. +14155551234"

cat <<EOF

Which WhatsApp account should OpenClaw log in as?
  1) A separate number just for Lyra (recommended): texts arrive as normal
     notifications, and you can reply to chat with Lyra.
  2) Your own number: texts go to your "Message yourself" chat, usually
     without a notification.
EOF
read -rp "Choose 1 or 2 [1]: " CHOICE
CHOICE="${CHOICE:-1}"

# --- Plugin + channel config -------------------------------------------------

log "Installing OpenClaw's WhatsApp plugin"
oc plugins install @openclaw/whatsapp || echo "(already installed)"

log "Configuring the WhatsApp channel"
# Only your number may message the agent. selfChatMode false stops texts that
# OpenClaw sends to itself (own-number setups) from being treated as requests.
oc config set channels.whatsapp \
  "{\"enabled\": true, \"dmPolicy\": \"allowlist\", \"allowFrom\": [\"$NUMBER\"], \"selfChatMode\": false}" \
  --strict-json --merge

# --- Link the account (QR) ---------------------------------------------------

if [[ "$CHOICE" == "2" ]]; then
  WHO="your own WhatsApp"
else
  WHO="the WhatsApp account for Lyra's separate number"
fi
cat <<EOF

────────────────────────────────────────────────────────────
 A QR code will appear. On the phone with $WHO:
   WhatsApp → Settings → Linked Devices → Link a Device
 and scan it. (Make the Terminal window big enough to show it.)
────────────────────────────────────────────────────────────
EOF
read -rp "Press Enter to show the QR code… " _
oc channels login --channel whatsapp

# --- Save the setting for Lyra ------------------------------------------------

mkdir -p "$(dirname "$ENV_FILE")"
touch "$ENV_FILE"
grep -v -E '^LYRA_(NOTIFY_TO|NOTIFY_CHANNEL|IMESSAGE_TO)=' "$ENV_FILE" > "$ENV_FILE.tmp" || true
{
  echo "LYRA_NOTIFY_CHANNEL=whatsapp"
  echo "LYRA_NOTIFY_TO=$NUMBER"
} >> "$ENV_FILE.tmp"
mv "$ENV_FILE.tmp" "$ENV_FILE"
if [[ "$MODE" == "server" ]]; then
  chown root:lyra "$ENV_FILE"; chmod 640 "$ENV_FILE"
else
  chmod 600 "$ENV_FILE"
fi

# --- Test ----------------------------------------------------------------------

sleep 3
log "Sending a test message to $NUMBER"
if oc message send --channel whatsapp --target "$NUMBER" --message "Lyra is connected to WhatsApp ✅"; then
  if [[ "$MODE" == "server" ]]; then
    systemctl restart lyra
    echo; echo " Done! Check WhatsApp for the test message. Lyra has been restarted."
  else
    cat <<EOF

 Done! Check WhatsApp for the test message.
 Now restart Lyra so it starts texting you:
   ./local/start.sh --tunnel
EOF
  fi
else
  cat <<EOF

 The test send failed. Check the WhatsApp link with:
   openclaw channels status --probe
 then run this script again.
EOF
  exit 1
fi
