from __future__ import annotations

import argparse
import sys
from collections.abc import Sequence
from pathlib import Path
from typing import TextIO

from pydantic import ValidationError

from .app import Error, Settings, bootstrap


def parser() -> argparse.ArgumentParser:
    argument_parser = argparse.ArgumentParser(
        description="Initialize Trilium Notes and reconcile its OIDC settings"
    )
    argument_parser.add_argument("--database", type=Path, required=True)
    argument_parser.add_argument("--base-url", required=True)
    argument_parser.add_argument("--password-file", type=Path, required=True)
    argument_parser.add_argument("--startup-timeout-seconds", type=float, default=120)
    argument_parser.add_argument("--poll-seconds", type=float, default=1)
    argument_parser.add_argument("--server-command", nargs=argparse.REMAINDER, required=True)
    return argument_parser


def run(arguments: Sequence[str], stderr: TextIO) -> int:
    options = parser().parse_args(arguments)
    try:
        settings = Settings(
            database=options.database,
            base_url=options.base_url,
            password_file=options.password_file,
            server_command=tuple(options.server_command),
            startup_timeout_seconds=options.startup_timeout_seconds,
            poll_seconds=options.poll_seconds,
        )
        bootstrap(settings)
    except (Error, OSError, ValidationError) as error:
        print(f"trilium-bootstrap: {error}", file=stderr)
        return 1
    return 0


def main() -> None:
    raise SystemExit(run(sys.argv[1:], sys.stderr))
