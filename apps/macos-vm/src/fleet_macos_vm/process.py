from __future__ import annotations

import os
import signal
import subprocess
import time
from collections.abc import Mapping, Sequence
from contextlib import suppress
from dataclasses import dataclass
from threading import Event
from typing import Protocol


class Cancelled(Exception):
    """The operator requested shutdown."""


@dataclass(frozen=True)
class Result:
    code: int
    stdout: str
    stderr: str

    def require_success(self, operation: str) -> None:
        if self.code:
            raise RuntimeError(f"{operation} failed ({self.code}): {self.stderr.strip()}")


class Child(Protocol):
    @property
    def returncode(self) -> int | None: ...

    def poll(self) -> int | None: ...

    def wait(self, timeout: float | None = None) -> int: ...

    def kill(self) -> None: ...


class CommandRunner(Protocol):
    cancelled: Event

    def check_cancelled(self) -> None: ...

    def start(self, arguments: Sequence[str]) -> Child: ...

    def run(
        self,
        arguments: Sequence[str],
        *,
        timeout: float = 30,
        input_data: bytes | None = None,
        capture: bool = True,
        cancellable: bool = True,
        environment: Mapping[str, str] | None = None,
    ) -> Result: ...


class Commands:
    def __init__(self, environment: Mapping[str, str], cancelled: Event) -> None:
        self.environment = dict(environment)
        self.cancelled = cancelled

    def check_cancelled(self) -> None:
        if self.cancelled.is_set():
            raise Cancelled

    def start(self, arguments: Sequence[str]) -> subprocess.Popen[bytes]:
        self.check_cancelled()
        return subprocess.Popen(
            arguments,
            env=self.environment,
            stdin=subprocess.DEVNULL,
            start_new_session=True,
        )

    def run(
        self,
        arguments: Sequence[str],
        *,
        timeout: float = 30,
        input_data: bytes | None = None,
        capture: bool = True,
        cancellable: bool = True,
        environment: Mapping[str, str] | None = None,
    ) -> Result:
        if cancellable:
            self.check_cancelled()
        deadline = time.monotonic() + timeout
        with subprocess.Popen(
            arguments,
            env=self.environment | dict(environment or {}),
            stdin=subprocess.PIPE if input_data is not None else subprocess.DEVNULL,
            stdout=subprocess.PIPE if capture else None,
            stderr=subprocess.PIPE if capture else None,
            start_new_session=True,
        ) as child:
            try:
                while True:
                    if cancellable:
                        self.check_cancelled()
                    if time.monotonic() >= deadline:
                        raise TimeoutError(f"{arguments[0]} timed out after {timeout:g} seconds")
                    try:
                        stdout, stderr = child.communicate(input_data, timeout=0.2)
                        return Result(
                            child.returncode,
                            (stdout or b"").decode(errors="replace"),
                            (stderr or b"").decode(errors="replace"),
                        )
                    except subprocess.TimeoutExpired:
                        input_data = None
            except BaseException:
                # sshpass owns an SSH child. Stop the whole session on timeout
                # or cancellation, including children still holding pipe ends.
                with suppress(ProcessLookupError):
                    os.killpg(child.pid, signal.SIGKILL)
                raise
            finally:
                child.wait()
