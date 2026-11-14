import argparse
import contextlib
import os
import signal
import subprocess
import sys
from collections.abc import Sequence
from typing import BinaryIO, Protocol


class Runner(Protocol):
    def __call__(self, args: Sequence[str]) -> None: ...


def run_sketchybar(args: Sequence[str]) -> None:
    with contextlib.suppress(OSError, subprocess.TimeoutExpired):
        subprocess.run(
            args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=2, check=False
        )


class Cancelled(Exception):
    pass


def cancel(signum: int, frame: object) -> None:
    raise Cancelled


def show_activity(
    sketchybar: str,
    background: str,
    foreground: str,
    label: str,
    item: str,
    stream: BinaryIO,
    run: Runner,
) -> None:
    try:
        run(
            [
                sketchybar,
                "--add",
                "item",
                item,
                "right",
                "--set",
                item,
                "icon=🔑",
                f"label={label}",
                "drawing=on",
                "background.drawing=on",
                f"background.color={background}",
                f"label.color={foreground}",
                "icon.font=Apple Color Emoji:Regular:14.0",
                "icon.padding_left=6",
                "icon.padding_right=0",
                "label.padding_left=4",
                "label.padding_right=6",
            ]
        )
        while stream.read(4096):
            pass
    finally:
        run([sketchybar, "--remove", item])


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--sketchybar", required=True)
    parser.add_argument("--background", required=True)
    parser.add_argument("--foreground", required=True)
    parser.add_argument("--label", required=True)
    args = parser.parse_args()
    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, cancel)
    with contextlib.suppress(Cancelled):
        show_activity(
            args.sketchybar,
            args.background,
            args.foreground,
            args.label,
            f"auth_request_{os.getpid()}",
            sys.stdin.buffer,
            run_sketchybar,
        )


if __name__ == "__main__":
    main()
