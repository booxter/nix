import argparse
import sys
from collections.abc import Mapping, Sequence
from pathlib import Path
from typing import TextIO

from sync_repo.config import ConfigurationError, load_repository_specs
from sync_repo.git import (
    RepositorySpec,
    RepositorySynchronizer,
    SyncError,
    SyncOutcome,
)


def main(
    argv: Sequence[str] | None = None,
    *,
    specs: Mapping[str, RepositorySpec] | None = None,
    synchronizer: RepositorySynchronizer | None = None,
    stdout: TextIO = sys.stdout,
    stderr: TextIO = sys.stderr,
) -> int:
    parser = argparse.ArgumentParser(
        prog="sync-repo",
        description="Synchronize a configured Git repository on demand.",
    )
    parser.add_argument("--config", type=Path, required=specs is None)
    parser.add_argument("name", nargs="?", help="configured repository name")
    arguments = parser.parse_args(argv)
    try:
        repositories = specs if specs is not None else load_repository_specs(arguments.config)
    except ConfigurationError as error:
        print(f"sync-repo: {error}", file=stderr)
        return 1

    if arguments.name is None:
        print("Available repositories:", file=stdout)
        for name in sorted(repositories):
            print(f"  {name}", file=stdout)
        return 0

    try:
        spec = repositories[arguments.name]
    except KeyError:
        print(f"sync-repo: unknown repository: {arguments.name}", file=stderr)
        return 2

    try:
        outcome = (synchronizer or RepositorySynchronizer()).sync(spec)
    except SyncError as error:
        print(f"sync-repo: {error}", file=stderr)
        return 1

    if outcome is SyncOutcome.CLONED:
        print(f"sync-repo: cloned {spec.name} into {spec.path}", file=stdout)
    elif outcome is SyncOutcome.PUSHED:
        print(f"sync-repo: pushed {spec.name} from {spec.path}", file=stdout)
    else:
        print(f"sync-repo: {spec.name} is up to date in {spec.path}", file=stdout)
    return 0
