from __future__ import annotations

import argparse
import sys
from pathlib import Path

from .artifact import create_artifact
from .model import load_artifact


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Create a consistent database backup artifact.")
    parser.add_argument("--config", required=True, type=Path)
    return parser


def run(arguments: list[str]) -> int:
    args = build_parser().parse_args(arguments)
    create_artifact(load_artifact(args.config))
    return 0


def main() -> None:
    try:
        status = run(sys.argv[1:])
    except (OSError, ValueError) as error:
        print(f"backup-artifact: {error}", file=sys.stderr)
        status = 1
    raise SystemExit(status)
