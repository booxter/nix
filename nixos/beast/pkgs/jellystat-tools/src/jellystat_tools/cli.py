from __future__ import annotations

import argparse
import sys
import time
from collections.abc import Callable, Sequence
from pathlib import Path

import httpx

from .api import JellystatApi, JellystatApiError
from .models import JellyfinConfiguration
from .service import (
    JellystatServiceError,
    create_backup,
    read_secret,
    reconcile_configuration,
)


def bootstrap_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Bootstrap Jellystat configuration")
    parser.add_argument("--url", required=True)
    parser.add_argument("--jellyfin-url", required=True)
    parser.add_argument("--jellyfin-api-key-file", required=True)
    parser.add_argument("--attempts", type=int, default=120)
    return parser


def backup_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Create a built-in Jellystat backup")
    parser.add_argument("--url", required=True)
    parser.add_argument("--backup-dir", required=True)
    parser.add_argument("--attempts", type=int, default=120)
    return parser


def api_client(base_url: str) -> httpx.Client:
    return httpx.Client(
        base_url=base_url,
        timeout=httpx.Timeout(30.0, connect=5.0),
        trust_env=False,
    )


def run_bootstrap(
    arguments: Sequence[str],
    *,
    sleep: Callable[[float], None],
) -> bool:
    args = bootstrap_parser().parse_args(arguments)
    configuration = JellyfinConfiguration(
        JF_HOST=str(args.jellyfin_url),
        JF_API_KEY=read_secret(Path(str(args.jellyfin_api_key_file))),
    )
    with api_client(str(args.url)) as client:
        return reconcile_configuration(
            JellystatApi(client),
            configuration,
            attempts=int(args.attempts),
            interval=2.0,
            sleep=sleep,
        )


def run_backup(
    arguments: Sequence[str],
    *,
    sleep: Callable[[float], None],
) -> Path:
    args = backup_parser().parse_args(arguments)
    with api_client(str(args.url)) as client:
        return create_backup(
            JellystatApi(client),
            Path(str(args.backup_dir)),
            attempts=int(args.attempts),
            interval=2.0,
            sleep=sleep,
        )


def bootstrap_main() -> None:
    try:
        reconciled = run_bootstrap(sys.argv[1:], sleep=time.sleep)
    except (JellystatApiError, JellystatServiceError) as error:
        print(error, file=sys.stderr)
        raise SystemExit(1) from error
    if not reconciled:
        print(
            "Jellystat is already configured and did not issue a bootstrap token; "
            "leaving app login unchanged.",
            file=sys.stderr,
        )


def backup_main() -> None:
    try:
        run_backup(sys.argv[1:], sleep=time.sleep)
    except (JellystatApiError, JellystatServiceError) as error:
        print(error, file=sys.stderr)
        raise SystemExit(1) from error
