from __future__ import annotations

import fcntl
import hashlib
import json
import math
import os
from collections.abc import Callable, Iterator, Sequence
from contextlib import AbstractContextManager, contextmanager
from pathlib import Path
from typing import Protocol

from atomic_file_writes import write_text_atomic


class Commands(Protocol):
    def reset(self) -> int: ...

    def run_pass(self, arguments: Sequence[str]) -> int: ...


class Session(Protocol):
    def locked(self) -> AbstractContextManager[None]: ...

    def last_used(self) -> float | None: ...

    def record(self, timestamp: float) -> None: ...


class FileSession:
    def __init__(self, state_directory: Path, homedir: str) -> None:
        # GnuPG authorization is shared by all stores using the same agent.
        identity = hashlib.sha256(homedir.encode()).hexdigest()
        self.directory = state_directory / "pass-idle"
        self.timestamp = self.directory / f"{identity}.json"
        self.lock = self.directory / f"{identity}.lock"

    @contextmanager
    def locked(self) -> Iterator[None]:
        self.directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        descriptor = os.open(self.lock, os.O_RDWR | os.O_CREAT, 0o600)
        with os.fdopen(descriptor, "r+") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            try:
                yield
            finally:
                fcntl.flock(lock, fcntl.LOCK_UN)

    def last_used(self) -> float | None:
        try:
            value = json.loads(self.timestamp.read_text())
        except (FileNotFoundError, ValueError):
            return None

        if type(value) not in (int, float):
            return None

        try:
            timestamp = float(value)
        except OverflowError:
            return None

        return timestamp if math.isfinite(timestamp) else None

    def record(self, timestamp: float) -> None:
        write_text_atomic(self.timestamp, json.dumps(timestamp) + "\n", mode=0o600)


def needs_session(arguments: Sequence[str]) -> bool:
    if not arguments:
        return False

    # ls/list are aliases of show, and git diff can decrypt via textconv.
    if list(arguments) in (["ls"], ["list"], ["show"]):
        return False

    return arguments[0] not in {
        "find",
        "search",
        "help",
        "--help",
        "version",
        "--version",
    }


def run_with_session(
    arguments: Sequence[str],
    *,
    commands: Commands,
    session: Session,
    clock: Callable[[], float],
    idle_seconds: int,
) -> int:
    # Hold the lock through interactive edits and reads: another pass invocation
    # must not stop the agent while this one is still using it.
    with session.locked():
        previous = session.last_used()
        now = clock()
        if previous is None or not 0 <= now - previous < idle_seconds:
            result = commands.reset()
            if result != 0:
                return result

        result = commands.run_pass(arguments)
        if result == 0:
            session.record(clock())
        return result
