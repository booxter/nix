from __future__ import annotations

import subprocess
from dataclasses import dataclass
from typing import Protocol


class FlashError(RuntimeError):
    """Expected operator-facing failure."""


@dataclass(frozen=True)
class Command:
    arguments: tuple[str, ...]
    stdin: str | None = None
    check: bool = True
    quiet: bool = False


class CommandRunner(Protocol):
    def run(self, command: Command) -> None: ...


@dataclass(frozen=True)
class SubprocessRunner:
    def run(self, command: Command) -> None:
        try:
            result = subprocess.run(
                command.arguments,
                input=command.stdin,
                text=True,
                stdout=subprocess.DEVNULL if command.quiet else None,
                stderr=subprocess.DEVNULL if command.quiet else None,
                check=False,
            )
        except OSError as error:
            if not command.check:
                return
            raise FlashError(f"could not execute {command.arguments[0]}: {error}") from error
        if command.check and result.returncode != 0:
            raise FlashError(f"{command.arguments[0]} failed with exit code {result.returncode}")
