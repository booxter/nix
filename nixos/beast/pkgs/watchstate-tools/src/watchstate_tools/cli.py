from __future__ import annotations

import argparse
import sys
from collections.abc import Callable, Sequence
from datetime import UTC, datetime
from pathlib import Path

from .auth import render_authentication
from .backup import create_backup
from .runtime import ContainerRuntime, PodmanRuntime


def auth_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Render WatchState authentication")
    parser.add_argument("--system-user", required=True)
    parser.add_argument("--password-file", required=True)
    parser.add_argument("--output", required=True)
    return parser


def backup_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Create a WatchState backup archive")
    parser.add_argument("--data-dir", required=True)
    parser.add_argument("--staging-dir", required=True)
    parser.add_argument("--keep", type=int, default=7)
    parser.add_argument("--podman-socket", default="http+unix:///run/podman/podman.sock")
    parser.add_argument("--container", default="watchstate")
    return parser


def run_auth(arguments: Sequence[str]) -> None:
    args = auth_parser().parse_args(arguments)
    render_authentication(
        system_user=str(args.system_user),
        password_file=Path(str(args.password_file)),
        output=Path(str(args.output)),
    )


def run_backup(
    arguments: Sequence[str],
    runtime_factory: Callable[[str, str], ContainerRuntime],
    *,
    now: Callable[[], datetime],
) -> Path:
    args = backup_parser().parse_args(arguments)
    result = create_backup(
        runtime_factory(str(args.podman_socket), str(args.container)),
        data_dir=Path(str(args.data_dir)),
        staging_dir=Path(str(args.staging_dir)),
        keep=int(args.keep),
        now=now,
    )
    return result.archive


def auth_main() -> None:
    run_auth(sys.argv[1:])


def backup_main() -> None:
    try:
        run_backup(sys.argv[1:], PodmanRuntime, now=lambda: datetime.now(UTC))
    except RuntimeError as error:
        print(error, file=sys.stderr)
        raise SystemExit(1) from error
