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
- `local/setup_whatsapp.sh`: one-time setup of OpenClaw's WhatsApp channel (plugin, allowlist of the owner's number, `selfChatMode: false`, QR login); works on the laptop and, run as root, on the server. Stores `LYRA_NOTIFY_CHANNEL`/`LYRA_NOTIFY_TO`.
- `local/setup_imessage.sh`: one-time setup of OpenClaw's iMessage channel (imsg + plugin + allowlist of the owner's handle); stores `LYRA_IMESSAGE_TO` in `~/.lyra/lyra.env`.
- `deploy/setup.sh`: idempotent Ubuntu 24.04 installer (Node 24, OpenClaw, uv, Caddy, ufw, systemd units).
- `deploy/lyra.service`, `deploy/Caddyfile`: service and HTTPS config used by setup.sh.

## Conventions
- The server is internet-facing: keep bearer-token auth mandatory (`LYRA_API_TOKEN`).
- `openclaw agent --json` returns top-level `payloads`; `extract_reply` also accepts the older `result.payloads` shape.
- The agent signals the end of a conversation with the `[END]` marker, which is stripped before speaking.
- Long tasks: `/chat` waits `LYRA_REPLY_WAIT` (4s; in practice Siri dropped hands-free replies that took ~7-8s) for the agent, then answers "I'm on it" and keeps the run going as a background job (one per session; OpenClaw runs one turn per session). While a task runs, responses include `waiting: true`; the Shortcut then sends `__lyra_poll__` (POLL_TEXT) instead of asking the user, and a poll waits up to `LYRA_REPLY_WAIT` for the result. Otherwise results are prepended to the speaker's next reply; "cancel" terminates the run. Keep voice turns under Siri's request timeout.
- Poll check-ins are silent (response has no `reply`; the Shortcut wraps Speak in "reply has any value"), except `LYRA_MIDWAY_MESSAGE` once after `LYRA_MIDWAY_AFTER` seconds.
- One request per conversation (`LYRA_ONE_SHOT`, default on): a final answer or task result ends the conversation unless it contains "?" anywhere (a clarifying question keeps it open, even when followed by more sentences).
- Answering by text: with texting set up (`LYRA_SESSION=auto`), voice uses the agent's main session `agent:<agent>:main`, where OpenClaw routes DMs by default (`session.dmScope: "main"`), so a WhatsApp reply to Lyra's own number continues the voice task. Needs a separate WhatsApp number for Lyra (with `selfChatMode: false`, self-chat messages are ignored).
- `/chat` includes `end_conversation: true` only when the conversation is over and omits it otherwise; the Shortcut tests it with "has any value" (Shortcuts can't reliably compare JSON booleans). Keep it that way.
- Texting (default WhatsApp, works laptop + server; iMessage is Mac-only): with `LYRA_NOTIFY_TO` set, every conversation line is texted live as its own message (`<speaker>: …`, `Lyra: …`; the background ack is `LYRA_WORKING_MESSAGE`, and results are texted when they finish), in order via a single outbox queue, using `openclaw message send --channel $LYRA_NOTIFY_CHANNEL`. Polls are never texted. Keep `selfChatMode: false` so self-sent texts never become agent input. Never commit the number.
