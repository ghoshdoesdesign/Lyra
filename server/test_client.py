#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["httpx"]
# ///
"""
Interactive command-line client for testing the Lyra server without Siri.

    LYRA_URL=https://<your-server> LYRA_API_TOKEN=... ./test_client.py
"""

import os
import sys

import httpx

URL = os.getenv("LYRA_URL", "http://127.0.0.1:7001").rstrip("/")
TOKEN = os.getenv("LYRA_API_TOKEN")
SPEAKER = os.getenv("LYRA_SPEAKER", "Test")


def main() -> None:
    headers = {"Authorization": f"Bearer {TOKEN}"} if TOKEN else {}
    print("🎤 Lyra Test Client")
    print(f"   Server: {URL}")
    print(f"   Speaker: {SPEAKER}")
    print("   Say 'goodbye' to exit\n")

    with httpx.Client(timeout=90, headers=headers) as client:
        try:
            health = client.get(f"{URL}/health")
            health.raise_for_status()
        except httpx.HTTPError as e:
            sys.exit(f"Server not reachable: {e}")

        while True:
            try:
                text = input("You: ").strip()
            except (EOFError, KeyboardInterrupt):
                print()
                break
            if not text:
                continue

            resp = client.post(f"{URL}/chat", json={"text": text, "speaker": SPEAKER})
            if resp.status_code != 200:
                print(f"[HTTP {resp.status_code}] {resp.text}\n")
                continue

            data = resp.json()
            print(f"Lyra: {data['reply']}\n")
            if data.get("end_conversation"):
                print("[Conversation ended]")
                break


if __name__ == "__main__":
    main()
