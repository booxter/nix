from __future__ import annotations

import json
import os
import sys
import time
from typing import Any


def emit(message: object) -> None:
    print(json.dumps(message, separators=(",", ":")), flush=True)


mode = os.environ.get("FAKE_CODEX_MODE", "mixed")

for line in sys.stdin:
    message: dict[str, Any] = json.loads(line)
    if message.get("id") == 1:
        emit({"id": 1, "result": {"userAgent": "fake"}})
    if message.get("id") != 2:
        continue
    if mode == "exit":
        raise SystemExit(7)
    if mode == "timeout":
        time.sleep(60)
        continue
    if mode == "malformed":
        print("{", flush=True)
        continue
    if mode == "thread-error":
        emit({"id": 2, "error": {"message": "could not start"}})
        continue

    emit({"id": 2, "result": {"thread": {"id": "fake-thread"}}})
    emit(
        {
            "method": "mcpServer/startupStatus/updated",
            "params": {
                "name": "ignored",
                "status": "ready",
                "error": None,
                "failureReason": None,
            },
        }
    )
    emit(
        {
            "method": "mcpServer/startupStatus/updated",
            "params": {
                "name": "alpha",
                "status": "starting",
                "error": None,
                "failureReason": None,
            },
        }
    )
    emit(
        {
            "method": "mcpServer/startupStatus/updated",
            "params": {
                "name": "alpha",
                "status": "ready" if mode != "cancelled" else "cancelled",
                "error": None,
                "failureReason": None,
            },
        }
    )
    if mode == "mixed":
        emit(
            {
                "method": "mcpServer/startupStatus/updated",
                "params": {
                    "name": "beta",
                    "status": "failed",
                    "error": "login required",
                    "failureReason": "reauthenticationRequired",
                },
            }
        )
