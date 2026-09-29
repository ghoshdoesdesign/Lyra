# Lyra: project notes

Voice access to an OpenClaw agent through AirPods, adapted from https://github.com/algal/clawpod.

## Requirements from the owner (do not regress)
- **Must run when the owner's laptop is off.** Everything server-side (OpenClaw Gateway + Lyra server) runs on an always-on cloud VPS via `deploy/setup.sh`. Never design anything that depends on the laptop being on.
- **Trigger phrase is "Hey Siri, it's showtime"**: an iOS Shortcut named "It's Showtime" (see SHORTCUT.md).
- **No custom iOS app** and nothing more complex than the Shortcut on the phone.
- **Uses OpenClaw** as the agent (installed on the VPS by the setup script).

## Layout
- `server/lyra_server.py`: FastAPI bridge. `POST /chat {text, speaker}` → `openclaw agent --json` → `{reply, end_conversation}`. Single-file uv script.
- `server/test_client.py`: interactive CLI client for testing without Siri.
- `deploy/setup.sh`: idempotent Ubuntu 24.04 installer (Node 24, OpenClaw, uv, Caddy, ufw, systemd units).
- `deploy/lyra.service`, `deploy/Caddyfile`: service and HTTPS config used by setup.sh.

## Conventions
- The server is internet-facing: keep bearer-token auth mandatory (`LYRA_API_TOKEN`).
- `openclaw agent --json` returns top-level `payloads`; `extract_reply` also accepts the older `result.payloads` shape.
- The agent signals the end of a conversation with the `[END]` marker, which is stripped before speaking.
