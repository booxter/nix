from __future__ import annotations

import argparse
import sys
from collections.abc import Sequence
from pathlib import Path

from .settings import reconcile


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description="Merge managed Degoog plugin settings")
    result.add_argument("--target", required=True)
    result.add_argument("--desired", required=True)
    return result


def run(arguments: Sequence[str]) -> None:
    args = parser().parse_args(arguments)
    reconcile(Path(str(args.target)), Path(str(args.desired)))


def main() -> None:
    run(sys.argv[1:])
