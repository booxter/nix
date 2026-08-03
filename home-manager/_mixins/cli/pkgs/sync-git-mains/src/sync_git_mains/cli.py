import argparse
import sys
from collections.abc import Sequence
from pathlib import Path
from typing import TextIO

from sync_git_mains.git import RepositorySynchronizer, SyncFailure


def _root(value: str, home: Path) -> Path:
    if value == "~":
        return home
    if value.startswith("~/"):
        return home / value.removeprefix("~/")
    return Path(value)


def main(
    argv: Sequence[str] | None = None,
    *,
    synchronizer: RepositorySynchronizer | None = None,
    home: Path | None = None,
    stdout: TextIO = sys.stdout,
    stderr: TextIO = sys.stderr,
) -> int:
    parser = argparse.ArgumentParser(
        prog="sync-git-mains",
        description="Fast-forward main or master branches in repositories below source roots.",
    )
    parser.add_argument("roots", nargs="*", default=["~/src"])
    arguments = parser.parse_args(argv)
    user_home = home or Path.home()
    sync = synchronizer or RepositorySynchronizer()
    failed = False

    for configured_root in arguments.roots:
        root = _root(configured_root, user_home)
        if not root.is_dir():
            print(f"sync-git-mains: warning: source root does not exist: {root}", file=stderr)
            failed = True
            continue
        for repository in sorted(root.iterdir()):
            if not repository.is_dir():
                continue
            try:
                branch = sync.sync(repository)
            except SyncFailure as error:
                print(f"sync-git-mains: warning: {error}", file=stderr)
                failed = True
                continue
            if branch:
                print(
                    f"sync-git-mains: advanced {branch} to origin/{branch} in {repository}",
                    file=stdout,
                )
    return 1 if failed else 0
