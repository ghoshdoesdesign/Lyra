#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = [
#     "fastapi",
#     "uvicorn[standard]",
# ]
# ///
"""
Lyra: AirPods ↔ OpenClaw voice bridge.

A FastAPI server that receives transcribed speech from an iOS Shortcut
(triggered by "Hey Siri, it's showtime"), routes it to an OpenClaw agent,
and returns the reply for Siri to speak in your AirPods.

Adapted from ClawPod (https://github.com/algal/clawpod). Intended to run on
an always-on cloud server next to the OpenClaw Gateway (see deploy/setup.sh),
so it keeps working when your laptop is off.

Architecture:
    AirPods → "Hey Siri, it's showtime"
        → iOS Shortcut (speech-to-text)
        → POST /chat (HTTPS + bearer token) to this server
        → openclaw agent CLI → OpenClaw Gateway (same server)
        → reply spoken aloud by Siri
"""

import asyncio
import json
import logging
import os
import re
import secrets
import shutil
from dataclasses import dataclass, field

from fastapi import Depends, FastAPI, HTTPException, Request
from pydantic import BaseModel

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------

HOST = os.getenv("LYRA_HOST", "127.0.0.1")
PORT = int(os.getenv("LYRA_PORT", "7001"))
LOG_LEVEL = os.getenv("LYRA_LOG_LEVEL", "INFO")

# Required unless LYRA_ALLOW_NO_AUTH=1: the server is reachable from the internet.
API_TOKEN = os.getenv("LYRA_API_TOKEN")
ALLOW_NO_AUTH = os.getenv("LYRA_ALLOW_NO_AUTH") == "1"

# OpenClaw settings
OPENCLAW_AGENT = os.getenv("LYRA_AGENT", "main")
# How long one agent run (a task) may take. Long jobs keep running in the
# background after the voice turn has been answered.
TASK_TIMEOUT = int(os.getenv("LYRA_TASK_TIMEOUT", "900"))
# How long a voice turn waits for the agent before answering "on it" and
# letting the task continue in the background. Siri gives up on slow requests.
REPLY_WAIT = float(os.getenv("LYRA_REPLY_WAIT", "25"))

# Session key prefix; each speaker gets their own conversation.
SESSION_PREFIX = os.getenv("LYRA_SESSION_PREFIX", "airpods")

# The agent appends this marker when the conversation should end.
END_MARKER = "[END]"

# Things the user can say to end the conversation.
USER_END_PHRASES = {
    "goodbye",
    "bye",
    "bye for now",
    "that's all",
    "thats all",
    "that’s all",  # curly apostrophe, as dictated by Siri
    "end conversation",
    "stop",
    "thanks lyra",
    "thank you lyra",
}

# Things the user can say to stop a running background task.
USER_CANCEL_PHRASES = {
    "cancel",
    "cancel that",
    "cancel it",
    "cancel the task",
    "stop that",
    "stop the task",
    "never mind",
    "nevermind",
}

# Questions that just ask how a background task is going.
STATUS_QUERY = re.compile(
    r"\b(any (update|news|progress)|updates?|status|is it (done|ready|finished)|"
    r"are you (done|finished)|how('?s| is) it going|what did you find)\b"
)

VOICE_STYLE_PREFIX = (
    "[Voice mode via AirPods. Actually do what the user asks: use your tools "
    "(web search, web pages, browser, files, commands, reminders) to complete "
    "tasks rather than just describing how. Before anything irreversible or "
    "costly (booking, buying, sending messages, deleting), say what you're about "
    "to do and ask for a yes first. Reply in 1-3 short spoken sentences, no "
    "emojis, no markdown, no URLs. If the user is wrapping up or says goodbye, "
    f"say a brief goodbye and end your reply with {END_MARKER}] "
)

logging.basicConfig(level=LOG_LEVEL.upper())
logger = logging.getLogger("lyra")

app = FastAPI(title="Lyra", version="1.0.0")

# -----------------------------------------------------------------------------
# Models
# -----------------------------------------------------------------------------

class ChatRequest(BaseModel):
    """Incoming chat request from the iOS Shortcut."""
    text: str
    speaker: str = "Unknown"


class ChatResponse(BaseModel):
    """
    Response back to the iOS Shortcut.

    end_conversation is only present (as true) when the conversation is over.
    Shortcuts can't reliably compare JSON booleans, but it can always test
    "Dictionary Value has any value", so absence means "keep going".
    """
    reply: str
    end_conversation: bool | None = None


# -----------------------------------------------------------------------------
# Auth
# -----------------------------------------------------------------------------

def require_auth(request: Request) -> None:
    """Bearer token auth (skipped only when explicitly disabled)."""
    if not API_TOKEN:
        return
    auth = request.headers.get("authorization", "")
    if not secrets.compare_digest(auth, f"Bearer {API_TOKEN}"):
        raise HTTPException(status_code=401, detail="Unauthorized")


# -----------------------------------------------------------------------------
# OpenClaw integration
# -----------------------------------------------------------------------------

def get_session_key(speaker: str) -> str:
    """Derive a per-speaker session key, e.g. "airpods-alexis"."""
    speaker_key = re.sub(r"[^a-z0-9]+", "-", speaker.lower()).strip("-")
    if not speaker_key or speaker_key == "unknown":
        speaker_key = "default"
    return f"{SESSION_PREFIX}-{speaker_key}"


def find_openclaw() -> str:
    """Find the openclaw CLI on PATH or in common npm install locations."""
    path = shutil.which("openclaw")
    if path:
        return path
    for candidate in ("~/.npm-global/bin/openclaw", "~/.volta/bin/openclaw"):
        candidate = os.path.expanduser(candidate)
        if os.path.exists(candidate):
            return candidate
    raise RuntimeError("openclaw not found on PATH, ~/.npm-global, or ~/.volta")


def extract_reply(result: dict) -> str:
    """
    Pull the reply text out of `openclaw agent --json` output.

    Current OpenClaw returns {"payloads": [{"text": ...}], ...}; older
    versions (the ones ClawPod targeted) nested it under "result".
    """
    payloads = result.get("payloads")
    if payloads is None:
        payloads = (result.get("result") or {}).get("payloads") or []
    texts = [p.get("text") or "" for p in payloads if isinstance(p, dict)]
    return "\n".join(t.strip() for t in texts if t.strip())


async def call_openclaw(message: str, session_key: str, speaker: str) -> str:
    """Run one agent turn through the OpenClaw Gateway and return its reply."""
    cmd = [
        find_openclaw(),
        "agent",
        "--agent", OPENCLAW_AGENT,
        "--session-key", session_key,
        "--message", f"{VOICE_STYLE_PREFIX}[speaker: {speaker}] {message}",
        "--timeout", str(TASK_TIMEOUT),
        "--json",
    ]

    logger.info(f"Calling openclaw: session={session_key} speaker={speaker}")

    proc = None
    try:
        proc = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        stdout, stderr = await asyncio.wait_for(
            proc.communicate(),
            timeout=TASK_TIMEOUT + 10,
        )

        if proc.returncode != 0:
            logger.error(f"openclaw error (exit {proc.returncode}): {stderr.decode()[-2000:]}")
            return "Sorry, I'm having trouble connecting right now. Try again in a moment."

        reply = extract_reply(json.loads(stdout.decode()))
        if not reply:
            logger.warning(f"Empty reply from openclaw: {stdout.decode()[:500]}")
            return "I'm not sure how to respond to that."
        return reply

    except asyncio.CancelledError:
        # The user cancelled the task; stop the agent run (openclaw aborts the
        # Gateway run on SIGTERM).
        if proc and proc.returncode is None:
            proc.terminate()
        raise
    except asyncio.TimeoutError:
        if proc and proc.returncode is None:
            proc.terminate()
        logger.error("openclaw timed out")
        return "Sorry, that took too long, so I stopped."
    except json.JSONDecodeError as e:
        logger.error(f"Failed to parse openclaw response: {e}")
        return "Sorry, something went wrong."
    except Exception as e:
        logger.error(f"openclaw call failed: {e}")
        return "Sorry, I couldn't process that request."


def is_user_goodbye(text: str) -> bool:
    """True when the whole utterance is a sign-off like "goodbye" or "that's all"."""
    return matches(text, USER_END_PHRASES)


def strip_end_marker(reply: str) -> tuple[str, bool]:
    """Remove the agent's end marker, reporting whether it was present."""
    if END_MARKER not in reply:
        return reply, False
    return reply.replace(END_MARKER, "").strip(), True


def matches(text: str, phrases: set[str]) -> bool:
    """True when the whole utterance is one of the given phrases."""
    normalized = re.sub(r"[^\w\s'’]", "", text.lower()).strip()
    return normalized in phrases


# -----------------------------------------------------------------------------
# Background tasks
# -----------------------------------------------------------------------------

@dataclass
class Job:
    """One agent run for a speaker, possibly outliving the voice turn."""
    request: str
    task: asyncio.Task
    detached: bool = False  # the voice turn stopped waiting; deliver later


# One running job per session: OpenClaw runs one turn per session at a time.
running_jobs: dict[str, Job] = {}
# Results of detached jobs, told to the user on their next turn.
pending_updates: dict[str, list[str]] = {}


def start_job(text: str, session_key: str, speaker: str) -> Job:
    job = Job(request=text, task=asyncio.create_task(call_openclaw(text, session_key, speaker)))
    running_jobs[session_key] = job

    def finished(task: asyncio.Task) -> None:
        if running_jobs.get(session_key) is job:
            del running_jobs[session_key]
        if job.detached and not task.cancelled():
            result, _ = strip_end_marker(task.result())
            logger.info(f"Background task done: session={session_key} result={result[:50]!r}")
            pending_updates.setdefault(session_key, []).append(result)

    job.task.add_done_callback(finished)
    return job


def short(text: str, words: int = 8) -> str:
    """First few words of a request, for spoken status messages."""
    parts = text.split()
    return " ".join(parts[:words]) + ("…" if len(parts) > words else "")


# -----------------------------------------------------------------------------
# Endpoints
# -----------------------------------------------------------------------------

@app.get("/")
async def root():
    """Friendly answer for people opening the server URL in a browser."""
    return {
        "service": "lyra",
        "status": "running",
        "hint": "Lyra is up. The Shortcut should use this address with /chat at the end.",
    }


@app.get("/health")
async def health():
    """Health check endpoint (no auth required)."""
    return {"status": "healthy", "service": "lyra"}


@app.post("/chat", response_model=ChatResponse, response_model_exclude_none=True)
async def chat(request: ChatRequest, _: None = Depends(require_auth)):
    """
    Process transcribed speech and return the agent's reply.

    The Shortcut sends {text, speaker}; we return {reply, end_conversation}.
    """
    text = request.text.strip()
    speaker = request.speaker.strip() or "Unknown"

    if not text:
        raise HTTPException(status_code=400, detail="Text is required")

    logger.info(f"Chat request: speaker={speaker} text={text[:50]!r}")

    session_key = get_session_key(speaker)
    updates = pending_updates.pop(session_key, [])
    update_text = " ".join(
        f"Update on your earlier request: {u.rstrip()}{'' if u.rstrip()[-1:] in '.!?' else '.'}"
        for u in updates
    )

    def respond(reply: str, end: bool = False) -> ChatResponse:
        if update_text:
            reply = f"{update_text} {reply}".strip()
        logger.info(f"Response: end={end} reply={reply[:50]!r}")
        return ChatResponse(reply=reply, end_conversation=True if end else None)

    # A task is still running in the background for this speaker.
    job = running_jobs.get(session_key)
    if job:
        if matches(text, USER_CANCEL_PHRASES):
            job.task.cancel()
            return respond(f"Okay, I stopped working on {short(job.request)}.")
        if is_user_goodbye(text):
            return respond("Okay, I'll keep working on it in the background. Bye!", end=True)
        return respond(
            f"I'm still working on {short(job.request)}. "
            "Ask me again in a minute, or say cancel to stop it."
        )

    # The user is just checking on a task that has since finished.
    if updates and STATUS_QUERY.search(text.lower()):
        return respond("")

    job = start_job(text, session_key, speaker)
    try:
        reply = await asyncio.wait_for(asyncio.shield(job.task), timeout=REPLY_WAIT)
    except asyncio.TimeoutError:
        job.detached = True
        logger.info(f"Task continues in background: session={session_key}")
        return respond(
            "I'm on it. This will take a little while. Ask me for an update in a "
            "minute, or come back later."
        )

    reply, agent_ended = strip_end_marker(reply)
    end_conversation = agent_ended or is_user_goodbye(text)
    return respond(reply or "Goodbye!", end=end_conversation)


# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

if __name__ == "__main__":
    import uvicorn

    if not API_TOKEN and not ALLOW_NO_AUTH:
        raise SystemExit(
            "LYRA_API_TOKEN is not set. Set it, or set LYRA_ALLOW_NO_AUTH=1 "
            "for local testing only."
        )

    logger.info(f"Starting Lyra on {HOST}:{PORT}")
    logger.info(f"Agent: {OPENCLAW_AGENT}, Session prefix: {SESSION_PREFIX}")

    uvicorn.run(app, host=HOST, port=PORT, log_level=LOG_LEVEL.lower())
