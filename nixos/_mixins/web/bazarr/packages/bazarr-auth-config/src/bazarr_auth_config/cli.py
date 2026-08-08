from __future__ import annotations

import argparse
import sys
from collections.abc import Sequence
from pathlib import Path

from .configuration import reconcile


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description="Disable Bazarr local authentication")
    result.add_argument("--config", required=True)
    result.add_argument("--uid", required=True, type=int)
    result.add_argument("--gid", required=True, type=int)
    return result


def run(arguments: Sequence[str]) -> None:
    args = parser().parse_args(arguments)
    reconcile(Path(str(args.config)), uid=int(args.uid), gid=int(args.gid))


def main() -> None:
    run(sys.argv[1:])
