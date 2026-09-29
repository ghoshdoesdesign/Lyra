# Lyra: project notes

Voice access to an OpenClaw agent through AirPods, adapted from https://github.com/algal/clawpod.

## Requirements from the owner (do not regress)
- **Target: must run when the owner's laptop is off.** The always-on path is a cloud VPS via `deploy/setup.sh`; keep it working. For v1 the owner also asked for a laptop mode (`local/start.sh`); it's a stepping stone, not a replacement, so features must work in both.
- **Trigger phrase is "Hey Siri, it's showtime"**: an iOS Shortcut named "It's Showtime" (see SHORTCUT.md).
- **No custom iOS app** and nothing more complex than the Shortcut on the phone.
- **Uses OpenClaw** as the agent (installed by `deploy/setup.sh` or `local/start.sh`).

## Layout
- `server/lyra_server.py`: FastAPI bridge. `POST /chat {text, speaker}` → `openclaw agent --json` → `{reply, end_conversation}`. Single-file uv script.
- `server/test_client.py`: interactive CLI client for testing without Siri.
- `local/start.sh`: v1 laptop mode (macOS/Linux). Installs OpenClaw via its official installer, onboards once, stores the token in `~/.lyra/lyra.env`, runs the server on 0.0.0.0; `--tunnel` adds a Cloudflare quick tunnel.
- `deploy/setup.sh`: idempotent Ubuntu 24.04 installer (Node 24, OpenClaw, uv, Caddy, ufw, systemd units).
- `deploy/lyra.service`, `deploy/Caddyfile`: service and HTTPS config used by setup.sh.

## Conventions
- The server is internet-facing: keep bearer-token auth mandatory (`LYRA_API_TOKEN`).
- `openclaw agent --json` returns top-level `payloads`; `extract_reply` also accepts the older `result.payloads` shape.
- The agent signals the end of a conversation with the `[END]` marker, which is stripped before speaking.
