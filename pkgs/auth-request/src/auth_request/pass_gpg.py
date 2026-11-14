import argparse
import contextlib
import os
import signal
import subprocess
from collections.abc import Sequence
from typing import IO, Protocol


class Process(Protocol):
    stdin: IO[bytes] | None

    def wait(self, timeout: float | None = None) -> int: ...
    def send_signal(self, sig: int) -> None: ...
    def kill(self) -> None: ...


class Launcher(Protocol):
    def indicator(self, path: str, label: str) -> Process: ...
    def gpg(self, path: str, args: Sequence[str]) -> Process: ...


class SubprocessLauncher:
    def indicator(self, path: str, label: str) -> Process:
        return subprocess.Popen(
            [path, "--label", label],
            stdin=subprocess.PIPE,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )

    def gpg(self, path: str, args: Sequence[str]) -> Process:
        # Preserve caller-supplied status/command descriptors. Python creates
        # the indicator pipe non-inheritable, so its lifetime stays with us.
        return subprocess.Popen([path, *args], close_fds=False)


class Cancelled(Exception):
    def __init__(self, signum: int) -> None:
        self.signum = signum


def cancel(signum: int, frame: object) -> None:
    raise Cancelled(signum)


def close_indicator(process: Process) -> None:
    if process.stdin is not None:
        with contextlib.suppress(OSError):
            process.stdin.close()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()


def run_gpg(path: str, indicator: str, label: str, args: Sequence[str], launcher: Launcher) -> int:
    lease = None
    # This covers pass decryption only. Global card activity requires a scdaemon
    # proxy for both stdio and the additional socket from GETINFO socket_name;
    # a stdio-only proxy misses other clients.
    # https://github.com/gpg/gnupg/blob/gnupg-2.4.9/agent/call-daemon.c
    if "-d" in args or "--decrypt" in args:
        with contextlib.suppress(OSError):
            lease = launcher.indicator(indicator, label)
    try:
        process = launcher.gpg(path, args)
        try:
            return process.wait()
        except Cancelled as exc:
            process.send_signal(exc.signum)
            process.wait()
            raise
    finally:
        if lease is not None:
            close_indicator(lease)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--gpg-program", required=True)
    parser.add_argument("--indicator", required=True)
    parser.add_argument("--label", required=True)
    parser.add_argument("args", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    gpg_args: list[str] = args.args
    if gpg_args and gpg_args[0] == "--":
        gpg_args = gpg_args[1:]
    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, cancel)
    try:
        status = run_gpg(
            args.gpg_program, args.indicator, args.label, gpg_args, SubprocessLauncher()
        )
    except Cancelled as exc:
        status = -exc.signum
    if status < 0:
        terminated_by = -status
        if terminated_by != signal.SIGKILL:
            signal.signal(terminated_by, signal.SIG_DFL)
        os.kill(os.getpid(), terminated_by)
    raise SystemExit(status)


if __name__ == "__main__":
    main()
