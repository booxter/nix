from io import BytesIO, StringIO
from pathlib import Path
from typing import Final

from dulwich import porcelain
from dulwich.errors import GitProtocolError, NotGitRepository, ObjectMissing
from dulwich.graph import can_fast_forward
from dulwich.refs import Ref
from dulwich.repo import Repo
from dulwich.worktree import list_worktrees

HEAD: Final = Ref(b"HEAD")
ORIGIN_HEAD: Final = Ref(b"refs/remotes/origin/HEAD")


class SyncFailure(Exception):
    """A repository cannot be updated safely."""


def _default_branch(repo: Repo, remote_symrefs: dict[Ref, Ref]) -> str | None:
    local_target = repo.refs.get_symrefs().get(ORIGIN_HEAD)
    targets = (local_target, remote_symrefs.get(HEAD))
    for target in targets:
        if target in {b"refs/remotes/origin/main", b"refs/heads/main"}:
            return "main"
        if target in {b"refs/remotes/origin/master", b"refs/heads/master"}:
            return "master"
    return None


def _is_dirty(path: Path) -> bool:
    state = porcelain.status(path)
    return bool(any(state.staged.values()) or state.unstaged or state.untracked)


class RepositorySynchronizer:
    def sync(self, path: Path) -> str | None:
        try:
            with Repo(str(path)) as repo:
                try:
                    repo.get_config_stack().get((b"remote", b"origin"), b"url")
                except KeyError:
                    return None

                try:
                    fetched = porcelain.fetch(
                        repo,
                        remote_location="origin",
                        outstream=StringIO(),
                        errstream=BytesIO(),
                        prune=True,
                        quiet=True,
                    )
                except (
                    porcelain.Error,
                    GitProtocolError,
                    NotGitRepository,
                    OSError,
                ) as error:
                    raise SyncFailure(f"fetch from origin failed: {path}: {error}") from error

                branch = _default_branch(repo, fetched.symrefs)
                if branch is None:
                    return None
                local_ref = Ref(f"refs/heads/{branch}".encode())
                remote_ref = Ref(f"refs/remotes/origin/{branch}".encode())
                try:
                    local_oid = repo.refs[local_ref]
                except KeyError:
                    return None
                try:
                    remote_oid = repo.refs[remote_ref]
                except KeyError as error:
                    raise SyncFailure(f"origin/{branch} was not fetched: {path}") from error

                if local_oid == remote_oid:
                    return None
                if not can_fast_forward(repo, local_oid, remote_oid):
                    raise SyncFailure(
                        f"{branch} cannot be fast-forwarded to origin/{branch} in {path}"
                    )

                worktree = next(
                    (tree for tree in list_worktrees(repo) if tree.branch == local_ref),
                    None,
                )
                if worktree is not None:
                    worktree_path = Path(worktree.path)
                    if _is_dirty(worktree_path):
                        raise SyncFailure(
                            f"{branch} is checked out with a dirty worktree; not updating {path}"
                        )
                    try:
                        porcelain.reset(worktree_path, "hard", remote_oid)
                    except (porcelain.Error, OSError, ValueError) as error:
                        raise SyncFailure(
                            f"fast-forward failed in worktree {worktree_path}: {error}"
                        ) from error
                elif not repo.refs.set_if_equals(local_ref, local_oid, remote_oid):
                    raise SyncFailure(f"{branch} changed while it was being updated in {path}")
                return branch
        except NotGitRepository:
            return None
        except (ObjectMissing, ValueError) as error:
            raise SyncFailure(f"cannot inspect repository {path}: {error}") from error
