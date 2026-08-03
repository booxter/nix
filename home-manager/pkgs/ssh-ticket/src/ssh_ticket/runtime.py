import os
import shlex
import subprocess
import sys
import time
from dataclasses import dataclass
from typing import NoReturn, Protocol, Sequence, TextIO


class CommandError(RuntimeError):
    pass


class CommandRunner(Protocol):
    def run(self, arguments: Sequence[str], *, capture: bool = True) -> str: ...

    def exec(self, arguments: Sequence[str]) -> NoReturn: ...


class Clock(Protocol):
    def now(self) -> int: ...


@dataclass(frozen=True)
class Runtime:
    commands: CommandRunner
    clock: Clock


@dataclass(frozen=True)
class SystemCommands:
    stderr: TextIO = sys.stderr

    def run(self, arguments: Sequence[str], *, capture: bool = True) -> str:
        process = subprocess.run(
            arguments,
            check=False,
            text=True,
            stdout=subprocess.PIPE if capture else None,
            stderr=subprocess.PIPE if capture else None,
        )
        if process.returncode != 0:
            if capture and process.stderr:
                self.stderr.write(process.stderr)
            raise CommandError(f"command failed: {shlex.join(arguments)}")
        return process.stdout if capture else ""

    def exec(self, arguments: Sequence[str]) -> NoReturn:
        os.execvp(arguments[0], list(arguments))
        raise AssertionError("unreachable")


@dataclass(frozen=True)
class SystemClock:
    def now(self) -> int:
        return int(time.time())


def system_runtime() -> Runtime:
    return Runtime(commands=SystemCommands(), clock=SystemClock())
