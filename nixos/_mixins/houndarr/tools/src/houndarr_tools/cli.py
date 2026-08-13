from __future__ import annotations

import argparse
import asyncio
import os
import sys
import time
from collections.abc import Callable, Mapping, Sequence
from pathlib import Path

import httpx

from .models import ReconcileConfiguration
from .reconcile import InstanceStore, ReconcileError, reconcile_instances
from .status import collect_status, write_status


def status_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Collect Houndarr operational status")
    parser.add_argument("--url", required=True)
    parser.add_argument("--metrics-file", required=True)
    return parser


def reconcile_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Reconcile declarative Houndarr instances")
    parser.add_argument("--data-dir", required=True)
    parser.add_argument("--config", required=True)
    return parser


def run_status(arguments: Sequence[str], *, now: float) -> bool:
    args = status_parser().parse_args(arguments)
    timeout = httpx.Timeout(30.0, connect=5.0)
    with httpx.Client(timeout=timeout) as client:
        snapshot = collect_status(client, str(args.url), now=now)
    write_status(Path(str(args.metrics_file)), snapshot)
    return snapshot.ok


def houndarr_store(data_dir: str) -> InstanceStore:
    from .houndarr_store import HoundarrStore

    return HoundarrStore(data_dir)


def run_reconcile(
    arguments: Sequence[str],
    environment: Mapping[str, str],
    *,
    store_factory: Callable[[str], InstanceStore] = houndarr_store,
) -> int:
    args = reconcile_parser().parse_args(arguments)
    credentials = environment.get("CREDENTIALS_DIRECTORY")
    if credentials is None:
        raise ReconcileError("CREDENTIALS_DIRECTORY is not set")
    configuration = ReconcileConfiguration.model_validate_json(
        Path(str(args.config)).read_text(encoding="utf-8")
    )
    return asyncio.run(
        reconcile_instances(
            store_factory(str(args.data_dir)),
            configuration.instances,
            Path(credentials),
        )
    )


def status_main() -> None:
    if not run_status(sys.argv[1:], now=time.time()):
        raise SystemExit(1)


def reconcile_main() -> None:
    try:
        changed = run_reconcile(sys.argv[1:], os.environ)
    except (ReconcileError, ValueError) as error:
        print(error, file=sys.stderr)
        raise SystemExit(1) from error
    print(f"Reconciled Houndarr instances: {changed} changed.")
