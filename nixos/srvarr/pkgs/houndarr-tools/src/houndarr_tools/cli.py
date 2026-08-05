from __future__ import annotations

import argparse
import sys
import time
from collections.abc import Callable, Sequence
from pathlib import Path

import httpx

from .readiness import ReadinessTimeout, wait_for_backends
from .status import collect_status, write_status


def wait_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Wait for Houndarr Arr backends")
    parser.add_argument("--url", action="append", required=True)
    parser.add_argument("--timeout-seconds", type=float, default=120.0)
    parser.add_argument("--interval-seconds", type=float, default=1.0)
    return parser


def status_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Collect Houndarr operational status")
    parser.add_argument("--url", required=True)
    parser.add_argument("--metrics-file", required=True)
    return parser


def run_wait(
    arguments: Sequence[str],
    *,
    clock: Callable[[], float],
    sleep: Callable[[float], None],
) -> None:
    args = wait_parser().parse_args(arguments)
    timeout = httpx.Timeout(2.0, connect=1.0)
    with httpx.Client(timeout=timeout) as client:
        wait_for_backends(
            client,
            tuple(str(url) for url in args.url),
            timeout=float(args.timeout_seconds),
            interval=float(args.interval_seconds),
            clock=clock,
            sleep=sleep,
        )


def run_status(arguments: Sequence[str], *, now: float) -> bool:
    args = status_parser().parse_args(arguments)
    timeout = httpx.Timeout(30.0, connect=5.0)
    with httpx.Client(timeout=timeout) as client:
        snapshot = collect_status(client, str(args.url), now=now)
    write_status(Path(str(args.metrics_file)), snapshot)
    return snapshot.ok


def wait_main() -> None:
    try:
        run_wait(sys.argv[1:], clock=time.monotonic, sleep=time.sleep)
    except ReadinessTimeout as error:
        print(error, file=sys.stderr)
        raise SystemExit(1) from error


def status_main() -> None:
    if not run_status(sys.argv[1:], now=time.time()):
        raise SystemExit(1)
