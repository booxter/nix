from collections.abc import Mapping
from dataclasses import dataclass
from enum import StrEnum
from io import BytesIO, StringIO
from pathlib import Path

from dulwich import porcelain
from dulwich.errors import GitProtocolError, NotGitRepository, ObjectMissing
from dulwich.graph import can_fast_forward
from dulwich.refs import Ref
from dulwich.repo import Repo


@dataclass(frozen=True)
class RepositorySpec:
    name: str
    remote: str
    path: Path


class SyncOutcome(StrEnum):
    CLONED = "cloned"
    PUSHED = "pushed"
    UP_TO_DATE = "up-to-date"


class SyncError(Exception):
    """A personal repository could not be synchronized safely."""


class RebaseFailed(SyncError):
    """A rebase stopped for manual conflict resolution."""


def repository_specs(
    home: Path,
    environ: Mapping[str, str],
) -> dict[str, RepositorySpec]:
    xdg_data = Path(environ.get("XDG_DATA_HOME", home / ".local" / "share"))
    password_store = Path(environ.get("PASSWORD_STORE_DIR", xdg_data / "password-store"))
    return {
        "gmailctl": RepositorySpec(
            "gmailctl",
            "git@github.com:booxter/gmailctl-private-config.git",
            home / ".gmailctl",
        ),
        "pass": RepositorySpec(
            "pass",
            "git@github.com:booxter/pass.git",
            password_store,
        ),
        "dotfiles": RepositorySpec(
            "dotfiles",
            "git@github.com:booxter/dotfiles.git",
            home / ".priv-bin",
        ),
    }


def _branch_upstream(repo: Repo, branch: bytes) -> tuple[str, Ref] | None:
    config = repo.get_config_stack()
    try:
        remote = config.get((b"branch", branch), b"remote")
        merge = config.get((b"branch", branch), b"merge")
    except KeyError:
        return None
    if remote == b".":
        return ".", Ref(merge)
    prefix = b"refs/heads/"
    if not merge.startswith(prefix):
        raise SyncError(f"unsupported upstream ref: {merge.decode(errors='replace')}")
    return remote.decode(), Ref(b"refs/remotes/" + remote + b"/" + merge.removeprefix(prefix))


def _set_origin_upstream(repo: Repo, branch: bytes) -> tuple[str, Ref]:
    config = repo.get_config()
    config.set((b"branch", branch), b"remote", b"origin")
    config.set((b"branch", branch), b"merge", b"refs/heads/" + branch)
    config.write_to_path()
    return "origin", Ref(b"refs/remotes/origin/" + branch)


def _push(repo: Repo, remote: str, branch_ref: Ref, *, set_upstream: bool) -> None:
    result = porcelain.push(
        repo,
        remote_location=remote,
        refspecs=f"{branch_ref.decode()}:{branch_ref.decode()}",
        outstream=BytesIO(),
        errstream=BytesIO(),
        set_upstream=set_upstream,
    )
    failures = [error for error in (result.ref_status or {}).values() if error]
    if failures:
        raise SyncError(f"push failed: {failures[0]}")


class RepositorySynchronizer:
    def sync(self, spec: RepositorySpec) -> SyncOutcome:
        if not spec.path.exists():
            spec.path.parent.mkdir(parents=True, exist_ok=True)
            try:
                cloned = porcelain.clone(
                    spec.remote,
                    spec.path,
                    errstream=BytesIO(),
                )
                cloned.close()
            except (porcelain.Error, GitProtocolError, NotGitRepository, OSError) as error:
                raise SyncError(f"clone failed: {error}") from error
            return SyncOutcome.CLONED

        try:
            repo = Repo(str(spec.path))
        except NotGitRepository as error:
            raise SyncError(f"{spec.name} is not a Git repository: {spec.path}") from error

        with repo:
            head_ref = repo.refs.get_symrefs().get(Ref(b"HEAD"))
            prefix = b"refs/heads/"
            if head_ref is None or not head_ref.startswith(prefix):
                raise SyncError(f"detached HEAD in {spec.path}; fix it manually")
            branch = head_ref.removeprefix(prefix)

            try:
                porcelain.fetch(
                    repo,
                    remote_location="origin",
                    outstream=StringIO(),
                    errstream=BytesIO(),
                    prune=True,
                    quiet=True,
                )
            except (porcelain.Error, GitProtocolError, NotGitRepository, OSError) as error:
                raise SyncError(f"fetch from origin failed: {error}") from error

            upstream = _branch_upstream(repo, branch)
            if upstream is None:
                origin_ref = Ref(b"refs/remotes/origin/" + branch)
                if origin_ref in repo.refs:
                    remote, upstream_ref = _set_origin_upstream(repo, branch)
                else:
                    try:
                        _push(repo, "origin", head_ref, set_upstream=True)
                    except (porcelain.Error, GitProtocolError, OSError) as error:
                        raise SyncError(f"push failed: {error}") from error
                    return SyncOutcome.PUSHED
            else:
                remote, upstream_ref = upstream

            try:
                upstream_oid = repo.refs[upstream_ref]
                local_oid = repo.head()
            except (KeyError, ObjectMissing) as error:
                raise SyncError(f"cannot resolve upstream {upstream_ref.decode()}") from error

            if not can_fast_forward(repo, upstream_oid, local_oid):
                try:
                    porcelain.rebase(repo, upstream_ref)
                except porcelain.Error as error:
                    raise RebaseFailed(
                        f"rebase failed in {spec.path}; resolve it there manually"
                    ) from error
                local_oid = repo.head()

            if local_oid == upstream_oid:
                return SyncOutcome.UP_TO_DATE
            if not can_fast_forward(repo, upstream_oid, local_oid):
                raise SyncError("local branch still diverges from its upstream after rebase")
            try:
                _push(repo, remote, head_ref, set_upstream=False)
            except (porcelain.Error, GitProtocolError, OSError) as error:
                raise SyncError(f"push failed: {error}") from error
            return SyncOutcome.PUSHED
