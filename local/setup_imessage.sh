#!/usr/bin/env bash
#
# Connect Lyra to iMessage through OpenClaw's built-in iMessage channel.
# Run once on the Mac that's signed in to Messages:
#
#   ./local/setup_imessage.sh
#
# Afterwards Lyra texts you each background task's result as soon as it's
# done, and the full conversation transcript when you say goodbye (or after a
# few minutes of silence). Replying to those texts talks to the same OpenClaw
# agent. Restart Lyra (./local/start.sh --tunnel) to pick up the setting.

set -euo pipefail

LYRA_DIR="$HOME/.lyra"
ENV_FILE="$LYRA_DIR/lyra.env"

log() { printf '\n\033[1;35m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mError: %s\033[0m\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || die "iMessage needs macOS (the Mac signed in to Messages)"
command -v brew >/dev/null || die "Homebrew is required: https://brew.sh"

# Use a supported Node for the openclaw CLI (same logic as local/start.sh).
NVM_SH="${NVM_DIR:-$HOME/.nvm}/nvm.sh"
if [[ -s "$NVM_SH" ]]; then
  set +eu; source "$NVM_SH"; nvm use 26 >/dev/null 2>&1 || nvm use 24 >/dev/null 2>&1; set -eu
fi
command -v openclaw >/dev/null || die "openclaw not found; run ./local/start.sh first"

# --- Who gets the texts ------------------------------------------------------

HANDLE="${1:-}"
if [[ -z "$HANDLE" ]]; then
  read -rp "Phone number (+1…) or Apple ID email to text transcripts to: " HANDLE
fi
HANDLE="$(printf '%s' "$HANDLE" | tr -d '[:space:]')"
[[ -n "$HANDLE" ]] || die "a phone number or email is required"

# --- imsg (OpenClaw's bridge to Messages.app) --------------------------------

if ! command -v imsg >/dev/null; then
  log "Installing imsg"
  brew install steipete/tap/imsg
fi
IMSG="$(command -v imsg)"

log "Installing OpenClaw's iMessage plugin"
openclaw plugins install @openclaw/imessage || echo "(already installed)"

log "Configuring the iMessage channel"
# Only you can message the agent back over iMessage.
openclaw config set channels.imessage "$(cat <<EOF
{"enabled": true, "cliPath": "$IMSG", "dbPath": "$HOME/Library/Messages/chat.db",
 "dmPolicy": "allowlist", "allowFrom": ["$HANDLE"]}
EOF
)" --strict-json --merge

# --- macOS permissions -------------------------------------------------------

cat <<EOF

────────────────────────────────────────────────────────────
 macOS needs two permissions (one time):

 1. Full Disk Access, so OpenClaw can read Messages:
    System Settings → Privacy & Security → Full Disk Access
    → turn on Terminal. Also click +, press ⌘⇧G, paste
      $(command -v node)
    and add it (that's the Node that runs OpenClaw's gateway).

 2. Automation, so it can send through Messages:
    a prompt will appear next — click OK / Allow.
────────────────────────────────────────────────────────────
EOF
read -rp "Press Enter once Full Disk Access is on… " _
"$IMSG" chats --limit 1 >/dev/null || echo "(if this failed, re-check Full Disk Access for Terminal)"

# --- Save the setting for Lyra ------------------------------------------------

mkdir -p "$LYRA_DIR"
touch "$ENV_FILE"
chmod 600 "$ENV_FILE"
grep -v '^LYRA_IMESSAGE_TO=' "$ENV_FILE" > "$ENV_FILE.tmp" || true
echo "LYRA_IMESSAGE_TO=$HANDLE" >> "$ENV_FILE.tmp"
mv "$ENV_FILE.tmp" "$ENV_FILE"

# --- Restart the gateway and send a test -------------------------------------

log "Restarting the OpenClaw Gateway"
launchctl kickstart -k "gui/$(id -u)/ai.openclaw.gateway" || openclaw gateway restart || true
for _ in $(seq 1 30); do (echo > /dev/tcp/127.0.0.1/18789) 2>/dev/null && break; sleep 2; done
sleep 3

log "Sending a test message to $HANDLE"
if openclaw message send --channel imessage --target "$HANDLE" --message "Lyra is connected to iMessage ✅"; then
  cat <<EOF

 Done! Check Messages on your iPhone for the test text.
 Now restart Lyra so it starts texting you:
   ./local/start.sh --tunnel
EOF
else
  cat <<EOF

 The test send failed. Check:
   openclaw channels status --probe
 and the permissions above, then run this script again.
EOF
  exit 1
fi
