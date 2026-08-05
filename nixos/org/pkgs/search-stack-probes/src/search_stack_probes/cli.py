from __future__ import annotations

import argparse
import sys
import time
from collections.abc import Sequence
from pathlib import Path

import httpx

from .metrics import searchless_registry, write_registry
from .probes import collect_searchless


def _timeout() -> httpx.Timeout:
    return httpx.Timeout(30.0, connect=5.0)


def searchless_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Collect Searchless API metrics")
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--metrics-file", required=True)
    return parser


def run_searchless(arguments: Sequence[str], *, now: float) -> None:
    args = searchless_parser().parse_args(arguments)
    with httpx.Client(base_url=str(args.base_url), timeout=_timeout(), trust_env=False) as client:
        snapshot = collect_searchless(client, now=now)
    write_registry(Path(str(args.metrics_file)), searchless_registry(snapshot))


def searchless_main() -> None:
    run_searchless(sys.argv[1:], now=time.time())
