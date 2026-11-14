from __future__ import annotations

import argparse
import os
import subprocess
import sys
import time
from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path

from pass_idle.session import FileSession, needs_session, run_with_session


@dataclass(frozen=True)
class SubprocessCommands:
    pass_program: str
    gpgconf: str

    def homedir(self) -> str:
        return subprocess.check_output([self.gpgconf, "--list-dirs", "homedir"], text=True).strip()

    def reset(self) -> int:
        # YubiKey PINs can be cached by gpg-agent as well as verified on-card.
        # Reset both; ordinary cache TTL settings do not expire CACHE_MODE_PIN.
        for daemon in ("scdaemon", "gpg-agent"):
            result = subprocess.call([self.gpgconf, "--kill", daemon])
            if result != 0:
                print(f"pass-idle: could not stop {daemon}; pass was not run", file=sys.stderr)
                return result
        return 0

    def run_pass(self, arguments: Sequence[str]) -> int:
        # Inherit the terminal and all three streams. Never capture passwords.
        return subprocess.call([self.pass_program, *arguments])


def positive_seconds(value: str) -> int:
    seconds = int(value)
    if seconds <= 0:
        raise argparse.ArgumentTypeError("idle timeout must be positive")
    return seconds


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pass-program", required=True)
    parser.add_argument("--gpgconf", required=True)
    parser.add_argument("--idle-seconds", type=positive_seconds, required=True)
    parser.add_argument("arguments", nargs=argparse.REMAINDER)
    options = parser.parse_args(argv)
    arguments = options.arguments
    if arguments[:1] == ["--"]:
        arguments = arguments[1:]

    commands = SubprocessCommands(options.pass_program, options.gpgconf)
    try:
        if needs_session(arguments):
            state_directory = Path(os.environ.get("XDG_STATE_HOME") or Path.home() / ".local/state")
            result = run_with_session(
                arguments,
                commands=commands,
                session=FileSession(state_directory, commands.homedir()),
                clock=time.time,
                idle_seconds=options.idle_seconds,
            )
        else:
            result = commands.run_pass(arguments)
    except KeyboardInterrupt:
        return 130
    except (OSError, subprocess.CalledProcessError) as error:
        print(f"pass-idle: {error}", file=sys.stderr)
        return 1

    return result if result >= 0 else 128 - result


if __name__ == "__main__":
    sys.exit(main())
