from __future__ import annotations

import argparse
import sys
import time
from collections.abc import Callable, Sequence
from pathlib import Path
from typing import TextIO

from .api import JellyfinApi, JellyfinApiError
from .service import (
    JellyfinServiceError,
    create_backup_artifact,
    read_secret,
    wait_for_idle,
)
from .systemd import PystemdUnitState, UnitState


def wait_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Wait for Jellyfin playback to become idle")
    parser.add_argument("--url", required=True)
    parser.add_argument("--api-key-file", required=True)
    parser.add_argument("--unit", default="jellyfin.service")
    parser.add_argument("--interval", type=float, default=30.0)
    return parser


def backup_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Create and stage a Jellyfin backup")
    parser.add_argument("--url", required=True)
    parser.add_argument("--api-key-file", required=True)
    parser.add_argument("--source-dir", required=True)
    parser.add_argument("--staging-dir", required=True)
    parser.add_argument("--keep-staging", type=int, default=7)
    parser.add_argument("--keep-source", type=int, default=1)
    return parser


def api(base_url: str, api_key_file: Path) -> JellyfinApi:
    return JellyfinApi(base_url, read_secret(api_key_file))


def run_wait(
    arguments: Sequence[str],
    unit_state: UnitState,
    *,
    sleep: Callable[[float], None],
    stderr: TextIO,
) -> None:
    args = wait_parser().parse_args(arguments)
    base_url = str(args.url)
    api_key_file = Path(str(args.api_key_file))
    wait_for_idle(
        unit_state,
        lambda: api(base_url, api_key_file).sessions(),
        unit_name=str(args.unit),
        interval=float(args.interval),
        sleep=sleep,
        stderr=stderr,
    )


def run_backup(arguments: Sequence[str]) -> Path:
    args = backup_parser().parse_args(arguments)
    client = api(str(args.url), Path(str(args.api_key_file)))
    result = create_backup_artifact(
        lambda: client.create_backup().path,
        source_dir=Path(str(args.source_dir)),
        staging_dir=Path(str(args.staging_dir)),
        keep_staging=int(args.keep_staging),
        keep_source=int(args.keep_source),
    )
    return result.destination


def wait_main() -> None:
    try:
        run_wait(
            sys.argv[1:],
            PystemdUnitState(),
            sleep=time.sleep,
            stderr=sys.stderr,
        )
    except (JellyfinApiError, JellyfinServiceError) as error:
        print(error, file=sys.stderr)
        raise SystemExit(1) from error


def backup_main() -> None:
    try:
        run_backup(sys.argv[1:])
    except (JellyfinApiError, JellyfinServiceError) as error:
        print(error, file=sys.stderr)
        raise SystemExit(1) from error
