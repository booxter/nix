from __future__ import annotations

import argparse
import os
import sys
import time
from collections.abc import Callable, Mapping, Sequence
from pathlib import Path

import httpx

from .api import AudiobookshelfError, HttpAudiobookshelfApi
from .reconcile import (
    configure_backups,
    read_backup_settings,
    read_oidc_settings,
    read_secret,
    reconcile_oidc,
)
from .systemd import SystemdUnitRestarter, UnitRestarter


def oidc_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Configure Audiobookshelf OIDC settings")
    parser.add_argument("--url", required=True)
    parser.add_argument("--api-token-file", required=True)
    parser.add_argument("--client-secret-file", required=True)
    parser.add_argument("--settings-file", required=True)
    parser.add_argument("--restart-unit", required=True)
    parser.add_argument("--wait-seconds", type=float, default=120.0)
    return parser


def backup_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Configure Audiobookshelf native backups")
    parser.add_argument("--url", required=True)
    token = parser.add_mutually_exclusive_group(required=True)
    token.add_argument("--api-token-file")
    token.add_argument("--credential-name")
    parser.add_argument("--settings-file", required=True)
    parser.add_argument("--retry-count", type=int, default=30)
    parser.add_argument("--retry-delay", type=float, default=2.0)
    return parser


def client(base_url: str, api_token: str) -> httpx.Client:
    return httpx.Client(
        base_url=base_url,
        headers={"Authorization": f"Bearer {api_token}"},
        timeout=httpx.Timeout(30.0, connect=5.0),
        trust_env=False,
    )


def run_oidc(
    arguments: Sequence[str],
    restarter: UnitRestarter,
    *,
    clock: Callable[[], float],
    sleep: Callable[[float], None],
) -> bool:
    args = oidc_parser().parse_args(arguments)
    with client(str(args.url), read_secret(Path(str(args.api_token_file)))) as http_client:
        return reconcile_oidc(
            HttpAudiobookshelfApi(http_client),
            read_oidc_settings(Path(str(args.settings_file))),
            read_secret(Path(str(args.client_secret_file))),
            restarter,
            str(args.restart_unit),
            timeout=float(args.wait_seconds),
            interval=2.0,
            clock=clock,
            sleep=sleep,
        )


def run_backup(
    arguments: Sequence[str],
    environment: Mapping[str, str],
    *,
    sleep: Callable[[float], None],
) -> None:
    args = backup_parser().parse_args(arguments)
    if args.api_token_file is not None:
        token_path = Path(str(args.api_token_file))
    else:
        credentials_directory = environment.get("CREDENTIALS_DIRECTORY")
        if credentials_directory is None:
            raise AudiobookshelfError("CREDENTIALS_DIRECTORY is not set")
        token_path = Path(credentials_directory) / str(args.credential_name)
    with client(str(args.url), read_secret(token_path)) as http_client:
        configure_backups(
            HttpAudiobookshelfApi(http_client),
            read_backup_settings(Path(str(args.settings_file))),
            retry_count=int(args.retry_count),
            retry_delay=float(args.retry_delay),
            sleep=sleep,
        )


def oidc_main() -> None:
    try:
        changed = run_oidc(
            sys.argv[1:],
            SystemdUnitRestarter(),
            clock=time.monotonic,
            sleep=time.sleep,
        )
    except AudiobookshelfError as error:
        print(error, file=sys.stderr)
        raise SystemExit(1) from error
    print(
        "Updated Audiobookshelf OIDC settings."
        if changed
        else "Audiobookshelf OIDC settings are already up to date."
    )


def backup_main() -> None:
    try:
        run_backup(sys.argv[1:], os.environ, sleep=time.sleep)
    except AudiobookshelfError as error:
        print(error, file=sys.stderr)
        raise SystemExit(1) from error
    print("Enabled daily Audiobookshelf backups.")
