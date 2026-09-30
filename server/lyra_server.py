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
import time
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
# Speed knobs. Lower thinking makes each model step much faster, which adds up
# over multi-step tasks; "" leaves OpenClaw's default. LYRA_MODEL optionally
# picks a faster model (e.g. one listed by `openclaw models list`).
THINKING = os.getenv("LYRA_THINKING", "low")
MODEL = os.getenv("LYRA_MODEL", "")
# How long a voice turn waits for the agent before answering "on it" and
# letting the task continue in the background. When Siri runs the Shortcut
# hands-free it abandons a request after only a few seconds; in practice
# replies that took ~7-8s (plus tunnel latency) never reached the phone, so
# stay well under that.
REPLY_WAIT = float(os.getenv("LYRA_REPLY_WAIT", "4"))

# Session key prefix; each speaker gets their own conversation.
SESSION_PREFIX = os.getenv("LYRA_SESSION_PREFIX", "airpods")
# "auto": share the agent's main session with WhatsApp when texting is set up;
# "main": always share it; "speaker": always one session per speaker.
SESSION = os.getenv("LYRA_SESSION", "auto").strip().lower()

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
    "thanks",
    "thank you",
    "perfect thank you",
    "perfect thanks",
}

# Sent by the Shortcut (instead of the user's words) to check on a running task.
POLL_TEXT = "__lyra_poll__"

# One request per conversation: end once Lyra has answered or finished the
# task, unless the reply is a question that needs an answer.
ONE_SHOT = os.getenv("LYRA_ONE_SHOT", "1") == "1"


def is_final(reply: str) -> bool:
    # A question anywhere ("What should it say? Once you tell me, I'll…")
    # needs an answer, so it keeps the conversation open.
    return ONE_SHOT and "?" not in reply


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
    # Absent on silent check-ins while a task runs; the Shortcut only speaks
    # when "reply has any value".
    reply: str | None = None
    end_conversation: bool | None = None
    # Present (as true) while a task is still running. The Shortcut then skips
    # "Ask for Input" and sends POLL_TEXT to hear the result as soon as it's
    # ready, without the user having to ask.
    waiting: bool | None = None


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
    """
    The OpenClaw session for this speaker's voice conversation.

    With texting set up, voice uses the agent's main session, which is where
    OpenClaw puts direct messages (session.dmScope "main", its default). Voice
    and WhatsApp then share one conversation, so a question Lyra asks by voice
    can be answered by text. Otherwise each speaker gets "airpods-<name>".
    """
    if SESSION == "main" or (SESSION == "auto" and NOTIFY_TO):
        return f"agent:{OPENCLAW_AGENT}:main"
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
    if THINKING:
        cmd += ["--thinking", THINKING]
    if MODEL:
        cmd += ["--model", MODEL]

    logger.info(f"Calling openclaw: session={session_key} speaker={speaker}")
    started = time.monotonic()

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
            # With --json, OpenClaw puts its error envelope ({"ok": false,
            # "error": {...}}) on stdout; stderr may be empty.
            out = stdout.decode()
            try:
                detail = json.loads(out).get("error") or {}
                reason = detail.get("message") if isinstance(detail, dict) else str(detail)
            except (json.JSONDecodeError, AttributeError):
                reason = ""
            err = "\n".join(x for x in (stderr.decode().strip(), reason or out.strip()) if x)
            logger.error(f"openclaw error (exit {proc.returncode}): {err[-2000:] or '(no details)'}")
            if re.search(r"no credits|insufficient.credits|insufficient_quota|exceeded your current quota|billing|\b402\b", err, re.I):
                return "Your AI account is out of credits. Add credits on your provider's billing page, then try again."
            return "Sorry, I'm having trouble connecting right now. Try again in a moment."

        reply = extract_reply(json.loads(stdout.decode()))
        logger.info(f"openclaw finished in {time.monotonic() - started:.1f}s: session={session_key}")
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
    started: float = field(default_factory=time.monotonic)
    announced: bool = False  # the one-time "I'll let you know" was said


# One running job per session: OpenClaw runs one turn per session at a time.
running_jobs: dict[str, Job] = {}
# Results of detached jobs, told to the user on their next turn.
pending_updates: dict[str, list[str]] = {}
# The most recent background result per session, so "what's the status?" can
# repeat it if Siri hung up before the result reached the phone.
last_results: dict[str, str] = {}


def start_job(text: str, session_key: str, speaker: str) -> Job:
    job = Job(request=text, task=asyncio.create_task(call_openclaw(text, session_key, speaker)))
    running_jobs[session_key] = job
    last_results.pop(session_key, None)  # a new request supersedes the old result

    def finished(task: asyncio.Task) -> None:
        if running_jobs.get(session_key) is job:
            del running_jobs[session_key]
        if job.detached and not task.cancelled():
            result, _ = strip_end_marker(task.result())
            logger.info(f"Background task done: session={session_key} result={result[:50]!r}")
            pending_updates.setdefault(session_key, []).append(result)
            last_results[session_key] = result
            # Text the result right away, in case Siri hung up before speaking it.
            text_line(ASSISTANT_NAME, result)

    job.task.add_done_callback(finished)
    return job


# -----------------------------------------------------------------------------
# Live conversation texts (via an OpenClaw channel: WhatsApp, iMessage…)
# -----------------------------------------------------------------------------

# Where to text the conversation; empty disables. LYRA_IMESSAGE_TO is the
# older iMessage-only setting and still works.
NOTIFY_TO = (os.getenv("LYRA_NOTIFY_TO") or os.getenv("LYRA_IMESSAGE_TO", "")).strip()
NOTIFY_CHANNEL = (
    os.getenv("LYRA_NOTIFY_CHANNEL")
    or ("imessage" if os.getenv("LYRA_IMESSAGE_TO") else "whatsapp")
).strip()
ASSISTANT_NAME = os.getenv("LYRA_NAME", "Lyra")
# Emoji in front of the assistant's texted lines ("🔱 Lyra: …"); empty for none.
ASSISTANT_EMOJI = os.getenv("LYRA_EMOJI", "🔱")
# Name shown for the user's lines when the Shortcut doesn't send a speaker.
USER_NAME = os.getenv("LYRA_USER_NAME", "You")
# Spoken and texted when a task continues in the background.
WORKING_MESSAGE = os.getenv("LYRA_WORKING_MESSAGE", "Hang in there while I finish your task.")
# While a task runs, check-ins are silent; after this many seconds Lyra says
# MIDWAY_MESSAGE once.
MIDWAY_AFTER = float(os.getenv("LYRA_MIDWAY_AFTER", "20"))
MIDWAY_MESSAGE = os.getenv("LYRA_MIDWAY_MESSAGE", "I'll let you know once I'm done.")

# One message per line of conversation, sent strictly in order.
outbox: asyncio.Queue | None = None


async def send_text(text: str) -> None:
    """Text NOTIFY_TO on NOTIFY_CHANNEL through `openclaw message send`."""
    try:
        proc = await asyncio.create_subprocess_exec(
            find_openclaw(), "message", "send",
            "--channel", NOTIFY_CHANNEL,
            "--target", NOTIFY_TO,
            "--message", text,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=60)
        if proc.returncode != 0:
            detail = (stderr.decode() + stdout.decode()).strip()
            logger.error(f"{NOTIFY_CHANNEL} send failed (exit {proc.returncode}): {detail[-1000:]}")
        else:
            logger.info(f"{NOTIFY_CHANNEL} message sent: {text[:50]!r}")
    except Exception as e:
        logger.error(f"{NOTIFY_CHANNEL} send failed: {e}")


async def outbox_worker() -> None:
    while True:
        text = await outbox.get()
        await send_text(text)


def text_line(who: str, text: str) -> None:
    """Queue one conversation line ("Sam: …", "Lyra: …") as its own message."""
    global outbox
    if not NOTIFY_TO or not text.strip():
        return
    if outbox is None:
        outbox = asyncio.Queue()
        asyncio.create_task(outbox_worker())
    prefix = f"{ASSISTANT_EMOJI} " if who == ASSISTANT_NAME and ASSISTANT_EMOJI else ""
    outbox.put_nowait(f"{prefix}{who}: {text.strip()}")


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

    is_poll = text == POLL_TEXT
    if not is_poll:
        text_line(speaker if speaker != "Unknown" else USER_NAME, text)

    def respond(reply: str, end: bool = False, waiting: bool = False) -> ChatResponse:
        # Background results are texted when they finish, so only the reply
        # to the user's own words is texted here.
        if not is_poll:
            text_line(ASSISTANT_NAME, reply)
        if update_text:
            reply = f"{update_text} {reply}".strip()
        logger.info(f"Response: end={end} waiting={waiting} reply={reply[:50]!r}")
        return ChatResponse(
            reply=reply,
            end_conversation=True if end else None,
            waiting=True if waiting else None,
        )

    async def wait_for_job(job: Job) -> bool:
        """Wait up to REPLY_WAIT for a running job; True if it finished."""
        try:
            await asyncio.wait_for(asyncio.shield(job.task), timeout=REPLY_WAIT)
        except asyncio.TimeoutError:
            return False
        except asyncio.CancelledError:
            if not job.task.cancelled():
                raise  # this request itself was cancelled
        await asyncio.sleep(0)  # let the job's done-callback record its result
        return True

    job = running_jobs.get(session_key)

    # The Shortcut checking on a running task: speak the result once it's ready.
    if text == POLL_TEXT:
        if job and not await wait_for_job(job):
            # Stay silent while working, except one reassurance midway.
            if not job.announced and time.monotonic() - job.started >= MIDWAY_AFTER:
                job.announced = True
                return respond(MIDWAY_MESSAGE, waiting=True)
            logger.info("Response: silent check-in (still working)")
            return ChatResponse(waiting=True)
        results = updates + pending_updates.pop(session_key, [])
        update_text = ""
        reply = " ".join(results) or "Done."
        return respond(reply, end=is_final(reply))

    # A task is still running in the background for this speaker.
    if job:
        if matches(text, USER_CANCEL_PHRASES):
            job.task.cancel()
            return respond(f"Okay, I stopped working on {short(job.request)}.")
        if is_user_goodbye(text):
            return respond("Okay, I'll keep working on it in the background. Bye!", end=True)
        if not await wait_for_job(job):
            return respond(
                f"I'm still working on {short(job.request)}. Say cancel to stop it.",
                waiting=True,
            )
        # It just finished: deliver the result, then treat this utterance as new.
        update_text = " ".join(pending_updates.pop(session_key, [])) or update_text
        if STATUS_QUERY.search(text.lower()):
            return respond("")

    # The user is just checking on a task that has since finished.
    elif STATUS_QUERY.search(text.lower()):
        if updates:
            return respond("")
        if session_key in last_results:
            # Repeat it: Siri may have hung up before it was spoken.
            return respond(f"The latest update: {last_results.pop(session_key)}")

    job = start_job(text, session_key, speaker)
    try:
        reply = await asyncio.wait_for(asyncio.shield(job.task), timeout=REPLY_WAIT)
    except asyncio.TimeoutError:
        job.detached = True
        logger.info(f"Task continues in background: session={session_key}")
        return respond(WORKING_MESSAGE, waiting=True)

    reply, agent_ended = strip_end_marker(reply)
    end_conversation = agent_ended or is_user_goodbye(text) or is_final(reply)
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
    logger.info(f"Agent: {OPENCLAW_AGENT}, Session: {get_session_key('Unknown')}")

    uvicorn.run(app, host=HOST, port=PORT, log_level=LOG_LEVEL.lower())
