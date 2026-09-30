# Lyra

Talk to your own AI agent through your AirPods. Say **"Hey Siri, it's showtime"**, then just talk; Lyra answers in your ears.

Lyra is adapted from [ClawPod](https://github.com/algal/clawpod) (a HomePod → OpenClaw bridge), with three changes:

- **AirPods instead of HomePod.** The Shortcut runs on your iPhone directly, so none of HomePod's Personal Content setup is needed.
- **Two ways to run it.** Start on your laptop (v1, no server needed), then move to a small cloud server so it keeps working when your laptop is off.
- **Secure by default.** Every request needs a bearer token.

## How it works

```
AirPods: "Hey Siri, it's showtime"
    ↓
iOS Shortcut "It's Showtime" (on your iPhone): Siri listens, speech → text
    ↓  HTTPS POST /chat {text, speaker} + bearer token
Cloud VPS (always on)
    ├─ Caddy: HTTPS, auto TLS certificate
    ├─ Lyra server (server/lyra_server.py)
    │     └─ openclaw agent --session-key airpods-<you> ...
    └─ OpenClaw Gateway (systemd service, OpenAI or Anthropic API key)
    ↓
{reply, end_conversation} → Siri speaks the reply in your AirPods → loop
```

## Quick start: run it on your laptop (v1)

The fastest way to try Lyra. You need a Mac (or Linux laptop) and an API key from [OpenAI](https://platform.openai.com/api-keys) or [Anthropic](https://console.anthropic.com).

```bash
git clone https://github.com/ghoshdoesdesign/Lyra.git
cd Lyra
./local/start.sh
```

On the first run it installs OpenClaw (and Node.js if needed), asks once for your API key (input hidden, OpenAI or Anthropic detected automatically), and creates an API token. Then it prints the **Server URL** and **API token** for the Shortcut ([SHORTCUT.md](SHORTCUT.md)). Later runs skip the setup.

**Which URL to use:**

| Command | Phone can reach Lyra | Server URL |
|---|---|---|
| `./local/start.sh` | Only on the same Wi-Fi as the laptop | `http://<your-mac>.local:7001` (stays the same) |
| `./local/start.sh --new-key` | (Re-)enter your API key, e.g. after rotating it. Otherwise the script reuses an existing OpenClaw login or `$OPENAI_API_KEY`/`$ANTHROPIC_API_KEY` from your shell and says so | same as above |
| `./local/start.sh --tunnel` | Anywhere, including cellular | `https://<random>.trycloudflare.com` (**changes every run**, so you'd update the Shortcut each time) |

**Laptop-mode limits:**
- Lyra only works while the script is running **and** the laptop is awake. Closing the lid stops it. The script keeps the Mac from idle-sleeping while it runs.
- On first run, macOS may ask to allow incoming connections for Python. Click **Allow**.
- For an always-on, fixed URL, move to a server (below). Your Shortcut then only needs its URL and token changed.

## iMessage transcripts (laptop mode)

Lyra can text you through OpenClaw's built-in iMessage channel:
- **✅ each background task's result** the moment it's done (so you get it even if Siri hung up), and
- **the full conversation transcript** when you say goodbye, or after 3 minutes of silence.

One-time setup on the Mac signed in to Messages:

```bash
./local/setup_imessage.sh        # asks for your phone number or Apple ID email
./local/start.sh --tunnel        # restart Lyra
```

The script installs `imsg` (OpenClaw's bridge to Messages.app) and the iMessage plugin, configures the channel so only your number can message the agent, walks you through Full Disk Access and Automation, and sends a test text. The number is stored in `~/.lyra/lyra.env` as `LYRA_IMESSAGE_TO`, not in the repo. This needs macOS, so it isn't available on a Linux server.

## Server setup: always on (about 20 minutes)

### 1. Get a server and an API key
- **VPS:** any Ubuntu 24.04 server with 2 GB+ RAM and a public IP. For example Hetzner CX22 (~€4/mo) or a DigitalOcean 2 GB droplet (~$12/mo). If the provider has its own firewall, allow inbound **TCP 22, 80 and 443**.
- **An API key** from [OpenAI](https://platform.openai.com/api-keys) or [Anthropic](https://console.anthropic.com). Keep it out of the repo; the setup script asks for it.

### 2. Install everything on the server

```bash
ssh root@<your-server-ip>
git clone https://github.com/ghoshdoesdesign/lyra.git
cd lyra
./deploy/setup.sh      # asks once for your API key (input hidden)
```

The script installs Node 24, OpenClaw, uv, Caddy and a firewall. It detects whether the key is OpenAI or Anthropic, onboards OpenClaw with it (stored only on the server, in `/home/lyra/.openclaw/`), and starts everything as services that restart on reboot. At the end it prints:

```
Server URL : https://203-0-113-7.sslip.io
API token  : 3f9c...
```

The URL uses [sslip.io](https://sslip.io), so you get working HTTPS without buying a domain. To use your own domain, point a DNS A record at the server and run with `LYRA_DOMAIN=lyra.example.com`.

If the repo is private, copy it to the server instead of cloning: `scp -r . root@<ip>:lyra`.

### 3. Test it from any computer

```bash
LYRA_URL=https://<server-url> LYRA_API_TOKEN=<token> uv run server/test_client.py
```

### 4. Set up the iPhone Shortcut
Follow [SHORTCUT.md](SHORTCUT.md) to create the **"It's Showtime"** Shortcut with your server URL and token.

### 5. Use it
With AirPods in, say **"Hey Siri, it's showtime."** Lyra greets you. Talk normally, and say **"goodbye"** or **"that's all"** when you're done.

## Operating the server

| Task | Command (on the VPS) |
|---|---|
| Lyra logs | `journalctl -u lyra -f` |
| OpenClaw Gateway logs | `sudo -iu lyra journalctl --user -u openclaw-gateway -f` |
| OpenClaw status | `sudo -iu lyra openclaw status` |
| Update OpenClaw + Lyra | `git pull && ./deploy/setup.sh` |
| Show the API token | `grep TOKEN /etc/lyra/lyra.env` |
| Rotate the token | edit `/etc/lyra/lyra.env`, then `systemctl restart lyra` (and update the Shortcut) |

OpenClaw's state (agent memory, sessions, persona files) lives in `/home/lyra/.openclaw/` on the server. Back it up occasionally.

## Configuration

Set these in `/etc/lyra/lyra.env` on the server:

| Variable | Default | Description |
|---|---|---|
| `LYRA_API_TOKEN` | (generated) | Bearer token the Shortcut must send (required) |
| `LYRA_AGENT` | `main` | OpenClaw agent id |
| `LYRA_REPLY_WAIT` | `4` | Seconds a voice turn waits before answering "I'm on it" and letting the task continue in the background |
| `LYRA_TASK_TIMEOUT` | `900` | Max seconds for one task (agent run) |
| `LYRA_THINKING` | `low` | Model thinking level per step (`off`, `minimal`, `low`, `medium`, `high`, …). Lower is faster; empty uses OpenClaw's default |
| `LYRA_IMESSAGE_TO` | (off) | iMessage handle for results and transcripts (set by `local/setup_imessage.sh`) |
| `LYRA_TRANSCRIPT_IDLE` | `180` | Seconds of silence before the transcript is texted |
| `LYRA_NAME` | `Lyra` | Assistant name used in transcripts |
| `LYRA_MODEL` | (OpenClaw default) | Optional faster model for voice, e.g. one from `openclaw models list` |
| `LYRA_SESSION_PREFIX` | `airpods` | Session key prefix; each speaker gets `airpods-<name>` |
| `LYRA_HOST` / `LYRA_PORT` | `127.0.0.1` / `7001` | Bind address (Caddy proxies to it) |

## Limitations
- The phrase is **"Hey Siri, it's showtime"**, not "Hey Lyra". iOS doesn't allow custom wake words without an app.
- **Siri may confuse the name.** It might mistake "it's showtime" for the Showtime or Paramount+ app or a song. If so, rename the Shortcut to something more distinctive (e.g. "Lyra showtime").
- **Long tasks run in the background.** If a task takes more than ~4 seconds, Lyra says "I'm on it" and keeps working. Ask "any update?" (or just start a new conversation later) and it tells you the result. Say "cancel" to stop it. There's no push notification yet, so you hear the result the next time you talk to Lyra.

## Getting Lyra to do work

Lyra runs on OpenClaw with its full tool set: web search (via your model provider), fetching web pages, a browser it can operate, files, shell commands and scheduled jobs. It's told to actually do tasks, and to ask for a "yes" before anything irreversible like booking, buying or sending a message. Things to try:

- "Find three well-reviewed Thai restaurants near Union Square open tonight and tell me which takes reservations."
- "Research the cheapest nonstop flights from SFO to New York next Friday."
- "Make a packing list for a 3-day ski trip and save it to a file on my Mac."

Real bookings through a browser work only on sites that allow it without a login or CAPTCHA, and are slow. Start with research tasks.
