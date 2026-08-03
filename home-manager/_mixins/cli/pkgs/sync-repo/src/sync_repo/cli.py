import argparse
import os
import sys
from collections.abc import Mapping, Sequence
from pathlib import Path
from typing import TextIO

from sync_repo.git import (
    RepositorySpec,
    RepositorySynchronizer,
    SyncError,
    SyncOutcome,
    repository_specs,
)


def main(
    argv: Sequence[str] | None = None,
    *,
    specs: Mapping[str, RepositorySpec] | None = None,
    synchronizer: RepositorySynchronizer | None = None,
    home: Path | None = None,
    environ: Mapping[str, str] | None = None,
    stdout: TextIO = sys.stdout,
    stderr: TextIO = sys.stderr,
) -> int:
    parser = argparse.ArgumentParser(
        prog="sync-repo",
        description="Synchronize one of: gmailctl, pass, dotfiles.",
    )
    parser.add_argument("name")
    arguments = parser.parse_args(argv)
    user_home = home or Path.home()
    environment = os.environ if environ is None else environ
    repositories = specs or repository_specs(user_home, environment)
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
