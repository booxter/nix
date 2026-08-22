from __future__ import annotations

import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol, Sequence


@dataclass(frozen=True)
class CommandResult:
    returncode: int
    stdout: str
    stderr: str


class CommandRunner(Protocol):
    def run(self, arguments: Sequence[str]) -> CommandResult:
        """Run one command without invoking a shell."""


class SubprocessCommandRunner:
    def run(self, arguments: Sequence[str]) -> CommandResult:
        completed = subprocess.run(arguments, check=False, capture_output=True, text=True)
        return CommandResult(completed.returncode, completed.stdout, completed.stderr)


class CommandError(RuntimeError):
    pass


def evaluate_json(
    runner: CommandRunner,
    nix: Path,
    expression: Path,
    arguments: Sequence[tuple[str, str]],
) -> str:
    command = [str(nix), str(expression), "--eval", "--strict", "--json"]
    for name, value in arguments:
        command.extend(("--argstr", name, value))
    result = runner.run(command)
    if result.returncode != 0:
        detail = result.stderr.strip() or f"exit status {result.returncode}"
        raise CommandError(f"Nix evaluation failed: {detail}")
    return result.stdout
