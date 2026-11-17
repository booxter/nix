"""Claude Code worktree hooks that keep checkouts outside the repository.

Claude runs `create` for `claude --worktree <name>` and the EnterWorktree tool,
and `remove` when the user discards a worktree. Each checkout lives at
~/.claude/worktrees/<repository>/<name> on a branch named exactly <name>.
"""

import subprocess
import sys
from pathlib import Path
from typing import Protocol, TextIO

from pydantic import BaseModel, ValidationError


class HookError(RuntimeError):
    """A failure Claude should show the user."""


class Git(Protocol):
    def run(self, cwd: Path, *arguments: str) -> str: ...


class GitCli:
    def run(self, cwd: Path, *arguments: str) -> str:
        completed = subprocess.run(
            ["git", *arguments], cwd=cwd, capture_output=True, text=True, check=False
        )
        if completed.returncode != 0:
            raise HookError(completed.stderr.strip() or f"git {arguments[0]} failed")
        return completed.stdout


class CreateRequest(BaseModel):
    cwd: Path
    name: str


class RemoveRequest(BaseModel):
    worktree_path: Path


def main_checkout(cwd: Path, git: Git) -> Path:
    # The common Git directory is shared by all worktrees, so this names the
    # repository even when Claude starts inside another worktree.
    common_dir = git.run(cwd, "rev-parse", "--path-format=absolute", "--git-common-dir")
    return Path(common_dir.strip()).parent


def registered_worktrees(cwd: Path, git: Git) -> set[Path]:
    listing = git.run(cwd, "worktree", "list", "--porcelain")
    prefix = "worktree "
    return {
        Path(line.removeprefix(prefix)).resolve()
        for line in listing.splitlines()
        if line.startswith(prefix)
    }


def branch_exists(cwd: Path, name: str, git: Git) -> bool:
    return git.run(cwd, "branch", "--list", name).strip() != ""


def create(request: CreateRequest, root: Path, git: Git) -> Path:
    path = root / main_checkout(request.cwd, git).name / request.name

    # Claude reopens a worktree when a name is reused.
    if path.resolve() in registered_worktrees(request.cwd, git):
        return path

    if branch_exists(request.cwd, request.name, git):
        git.run(request.cwd, "worktree", "add", str(path), request.name)
    else:
        # HEAD is resolved in the checkout where Claude started.
        git.run(request.cwd, "worktree", "add", "-b", request.name, str(path), "HEAD")
    return path


def remove(request: RemoveRequest, git: Git) -> None:
    # Git refuses to remove the worktree it runs in, so run from the main
    # checkout. Without --force, uncommitted work fails the removal. The branch
    # is kept because its name was chosen on purpose.
    repository = main_checkout(request.worktree_path, git)
    git.run(repository, "worktree", "remove", str(request.worktree_path))


def run(
    arguments: list[str], stdin: TextIO, stdout: TextIO, stderr: TextIO, root: Path, git: Git
) -> int:
    try:
        match arguments:
            case ["create"]:
                path = create(CreateRequest.model_validate_json(stdin.read()), root, git)
                # Claude reads the worktree path from stdout, so print nothing else.
                print(path, file=stdout)
            case ["remove"]:
                remove(RemoveRequest.model_validate_json(stdin.read()), git)
            case _:
                print("usage: claude-worktree create|remove < hook-input.json", file=stderr)
                return 2
    except (HookError, ValidationError) as error:
        print(error, file=stderr)
        return 1
    return 0


def main() -> None:
    root = Path.home() / ".claude" / "worktrees"
    sys.exit(run(sys.argv[1:], sys.stdin, sys.stdout, sys.stderr, root, GitCli()))
