from __future__ import annotations

import argparse
import sys
import time
from collections.abc import Callable, Sequence
from pathlib import Path

import httpx

from .api import PinepodsApi, PinepodsApiError
from .database import Database, PsycopgDatabase
from .models import CreateAdminRequest
from .service import (
    PinepodsServiceError,
    bootstrap_admin,
    native_backup,
    read_secret,
)


def bootstrap_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Bootstrap the first PinePods administrator")
    parser.add_argument("--url", required=True)
    parser.add_argument("--username", required=True)
    parser.add_argument("--full-name", required=True)
    parser.add_argument("--email-file", required=True)
    parser.add_argument("--password-file", required=True)
    parser.add_argument("--attempts", type=int, default=120)
    return parser


def backup_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Create and prune PinePods native backups")
    parser.add_argument("--url", required=True)
    parser.add_argument("--database", required=True)
    parser.add_argument("--keep", type=int, default=7)
    parser.add_argument("--attempts", type=int, default=3600)
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
) -> int | str | None:
    args = bootstrap_parser().parse_args(arguments)
    request = CreateAdminRequest(
        username=str(args.username),
        fullname=str(args.full_name),
        email=read_secret(Path(str(args.email_file))),
        password=read_secret(Path(str(args.password_file))),
    )
    with api_client(str(args.url)) as client:
        return bootstrap_admin(
            PinepodsApi(client),
            request,
            attempts=int(args.attempts),
            interval=2.0,
            sleep=sleep,
        )


def run_backup(
    arguments: Sequence[str],
    database_factory: Callable[[str], Database],
    *,
    sleep: Callable[[float], None],
) -> tuple[str, ...]:
    args = backup_parser().parse_args(arguments)
    with api_client(str(args.url)) as client:
        return native_backup(
            PinepodsApi(client),
            database_factory(str(args.database)),
            keep=int(args.keep),
            attempts=int(args.attempts),
            interval=2.0,
            sleep=sleep,
        )


def bootstrap_main() -> None:
    try:
        user_id = run_bootstrap(sys.argv[1:], sleep=time.sleep)
    except (PinepodsApiError, PinepodsServiceError) as error:
        print(error, file=sys.stderr)
        raise SystemExit(1) from error
    if user_id is None:
        print("PinePods already has an administrator")
    else:
        print(f"Created the initial PinePods administrator (user ID {user_id})")


def backup_main() -> None:
    try:
        run_backup(sys.argv[1:], PsycopgDatabase, sleep=time.sleep)
    except (PinepodsApiError, PinepodsServiceError) as error:
        print(error, file=sys.stderr)
        raise SystemExit(1) from error
