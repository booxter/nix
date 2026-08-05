from __future__ import annotations

import argparse
import sys
from collections.abc import Sequence
from pathlib import Path

from .role import read_secret, set_role_password


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(
        description="Set a PostgreSQL role password from a secret file"
    )
    result.add_argument("--database", required=True)
    result.add_argument("--role", required=True)
    result.add_argument("--password-file", required=True)
    return result


def run(arguments: Sequence[str]) -> None:
    args = parser().parse_args(arguments)
    set_role_password(
        str(args.database),
        str(args.role),
        read_secret(Path(str(args.password_file))),
    )


def main() -> None:
    run(sys.argv[1:])
