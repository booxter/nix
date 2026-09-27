from __future__ import annotations

import os
import subprocess
from dataclasses import dataclass
from typing import Protocol


class RiskError(RuntimeError):
    """An expected operator-facing failure."""


@dataclass(frozen=True)
class CommandResult:
    stdout: str
    returncode: int


class CommandRunner(Protocol):
    def run(
        self,
        arguments: tuple[str, ...],
        *,
        stdin: str | None = None,
        accepted_codes: tuple[int, ...] = (0,),
        environment: dict[str, str] | None = None,
    ) -> CommandResult: ...


@dataclass(frozen=True)
class SubprocessRunner:
    def run(
        self,
        arguments: tuple[str, ...],
        *,
        stdin: str | None = None,
        accepted_codes: tuple[int, ...] = (0,),
        environment: dict[str, str] | None = None,
    ) -> CommandResult:
        try:
            result = subprocess.run(
                arguments,
                input=stdin,
                text=True,
                stdout=subprocess.PIPE,
                env=os.environ | (environment or {}),
                check=False,
            )
        except OSError as error:
            raise RiskError(f"could not execute {arguments[0]}: {error}") from error
        if result.returncode not in accepted_codes:
            raise RiskError(f"{arguments[0]} failed with exit code {result.returncode}")
        return CommandResult(stdout=result.stdout, returncode=result.returncode)
