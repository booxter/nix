from __future__ import annotations

import subprocess
import threading
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol, Sequence, TextIO


@dataclass(frozen=True)
class CommandResult:
    returncode: int
    stdout: str
    stderr: str


class CommandRunner(Protocol):
    def run(self, arguments: Sequence[str]) -> CommandResult:
        """Run one command without invoking a shell."""

    def run_streaming(self, arguments: Sequence[str], stderr: TextIO) -> CommandResult:
        """Run one command while streaming its standard error."""


class SubprocessCommandRunner:
    def run(self, arguments: Sequence[str]) -> CommandResult:
        completed = subprocess.run(
            arguments,
            check=False,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
        )
        return CommandResult(completed.returncode, completed.stdout, completed.stderr)

    def run_streaming(self, arguments: Sequence[str], stderr: TextIO) -> CommandResult:
        process = subprocess.Popen(
            arguments,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            errors="replace",
            bufsize=1,
        )
        assert process.stdout is not None
        assert process.stderr is not None
        process_stdout = process.stdout
        process_stderr = process.stderr

        def stream_standard_error() -> None:
            for line in process_stderr:
                stderr.write(line)
                stderr.flush()

        stderr_thread = threading.Thread(target=stream_standard_error)
        stderr_thread.start()
        stdout = process_stdout.read()
        returncode = process.wait()
        stderr_thread.join()
        return CommandResult(returncode, stdout, "")


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
