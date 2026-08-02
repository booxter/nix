from dataclasses import dataclass
from io import BytesIO, StringIO
from pathlib import Path

from dulwich import porcelain
from dulwich.repo import Repo

from sync_git_mains.cli import main

IDENTITY = b"Test <test@example.com>"


@dataclass(frozen=True)
class RepositoryFixture:
    remote: Path
    seed: Path
    checkout: Path
    branch: str


def commit_file(repository: Path, filename: str, content: str, message: str) -> bytes:
    (repository / filename).write_text(content, encoding="utf-8")
    porcelain.add(repository, paths=[filename])
    return porcelain.commit(
        repository,
        message=message,
        author=IDENTITY,
        committer=IDENTITY,
    )


def push(repository: RepositoryFixture) -> None:
    reference = f"refs/heads/{repository.branch}"
    porcelain.push(
        repository.seed,
        remote_location="origin",
        refspecs=f"{reference}:{reference}",
        outstream=BytesIO(),
        errstream=BytesIO(),
    )


def make_repository(home: Path, root: Path, name: str, branch: str) -> RepositoryFixture:
    remote = root / f"{name}.git"
    seed = root / f"{name}-seed"
    checkout = home / "src" / name
    reference = f"refs/heads/{branch}".encode()

    with porcelain.init(remote, bare=True) as bare:
        bare.refs.set_symbolic_ref(b"HEAD", reference)
    with porcelain.init(seed) as local:
        local.refs.set_symbolic_ref(b"HEAD", reference)
    commit_file(seed, "value", "base\n", "base")
    porcelain.remote_add(seed, "origin", str(remote))
    repository = RepositoryFixture(remote, seed, checkout, branch)
    push(repository)
    cloned = porcelain.clone(str(remote), checkout, errstream=BytesIO())
    cloned.close()
    return repository


def add_remote_commit(repository: RepositoryFixture, filename: str = "remote") -> bytes:
    commit = commit_file(repository.seed, filename, "remote\n", "remote")
    push(repository)
    return commit


def run_sync(home: Path, arguments: list[str] | None = None) -> tuple[int, str, str]:
    stdout = StringIO()
    stderr = StringIO()
    status = main(arguments, home=home, stdout=stdout, stderr=stderr)
    return status, stdout.getvalue(), stderr.getvalue()


def ref(repository: Path, name: str) -> bytes:
    with Repo(str(repository)) as repo:
        return repo.refs[name.encode()]


def current_branch(repository: Path) -> bytes | None:
    with Repo(str(repository)) as repo:
        return repo.refs.get_symrefs().get(b"HEAD")


def test_discovers_and_fast_forwards_checked_out_main_branches(tmp_path: Path) -> None:
    home = tmp_path / "home"
    (home / "src").mkdir(parents=True)
    main = make_repository(home, tmp_path, "main-repo", "main")
    master = make_repository(home, tmp_path, "master-repo", "master")
    (home / "src" / "not-a-repository").mkdir()
    (home / "src" / "not-a-directory").write_text("ignored\n", encoding="utf-8")
    no_origin = porcelain.init(home / "src" / "no-origin")
    no_origin.close()
    main_remote = add_remote_commit(main)
    master_remote = add_remote_commit(master)

    status, stdout, stderr = run_sync(home)

    assert status == 0
    assert stderr == ""
    assert "advanced main to origin/main" in stdout
    assert "advanced master to origin/master" in stdout
    assert ref(main.checkout, "refs/heads/main") == main_remote
    assert ref(master.checkout, "refs/heads/master") == master_remote

    repeated_status, repeated_stdout, repeated_stderr = run_sync(home)
    assert repeated_status == 0
    assert repeated_stdout == ""
    assert repeated_stderr == ""


def test_updates_default_branch_that_is_not_checked_out(tmp_path: Path) -> None:
    home = tmp_path / "home"
    (home / "src").mkdir(parents=True)
    repository = make_repository(home, tmp_path, "repo", "main")
    with Repo(str(repository.checkout)) as repo:
        feature_oid = repo.refs[b"refs/heads/main"]
        repo.refs[b"refs/heads/feature"] = feature_oid
        repo.refs.set_symbolic_ref(b"HEAD", b"refs/heads/feature")
    remote_oid = add_remote_commit(repository)

    status, _, stderr = run_sync(home, [str(home / "src")])

    assert status == 0
    assert stderr == ""
    assert current_branch(repository.checkout) == b"refs/heads/feature"
    assert ref(repository.checkout, "HEAD") == feature_oid
    assert ref(repository.checkout, "refs/heads/main") == remote_oid


def test_does_not_create_missing_local_default_branch(tmp_path: Path) -> None:
    home = tmp_path / "home"
    (home / "src").mkdir(parents=True)
    repository = make_repository(home, tmp_path, "repo", "main")
    with Repo(str(repository.checkout)) as repo:
        repo.refs[b"refs/heads/feature"] = repo.refs[b"refs/heads/main"]
        repo.refs.set_symbolic_ref(b"HEAD", b"refs/heads/feature")
        del repo.refs[b"refs/heads/main"]
    add_remote_commit(repository)

    status, _, stderr = run_sync(home)

    assert status == 0
    assert stderr == ""
    with Repo(str(repository.checkout)) as repo:
        assert b"refs/heads/main" not in repo.refs


def test_does_not_change_diverged_default_branch(tmp_path: Path) -> None:
    home = tmp_path / "home"
    (home / "src").mkdir(parents=True)
    repository = make_repository(home, tmp_path, "repo", "main")
    local_oid = commit_file(repository.checkout, "local", "local\n", "local")
    add_remote_commit(repository)

    status, _, stderr = run_sync(home)

    assert status == 1
    assert "main cannot be fast-forwarded to origin/main" in stderr
    assert ref(repository.checkout, "refs/heads/main") == local_oid


def test_does_not_update_dirty_checked_out_branch(tmp_path: Path) -> None:
    home = tmp_path / "home"
    (home / "src").mkdir(parents=True)
    repository = make_repository(home, tmp_path, "repo", "master")
    add_remote_commit(repository)
    (repository.checkout / "dirty").write_text("dirty\n", encoding="utf-8")
    local_oid = ref(repository.checkout, "refs/heads/master")

    status, _, stderr = run_sync(home)

    assert status == 1
    assert "master is checked out with a dirty worktree" in stderr
    assert ref(repository.checkout, "refs/heads/master") == local_oid


def test_missing_root_does_not_block_other_roots(tmp_path: Path) -> None:
    home = tmp_path / "home"
    (home / "src").mkdir(parents=True)
    repository = make_repository(home, tmp_path, "repo", "main")
    remote_oid = add_remote_commit(repository)

    status, stdout, stderr = run_sync(
        home,
        [str(home / "missing"), str(home / "src")],
    )

    assert status == 1
    assert f"source root does not exist: {home / 'missing'}" in stderr
    assert "advanced main to origin/main" in stdout
    assert ref(repository.checkout, "refs/heads/main") == remote_oid


def test_ignores_other_default_branches(tmp_path: Path) -> None:
    home = tmp_path / "home"
    (home / "src").mkdir(parents=True)
    repository = make_repository(home, tmp_path, "repo", "develop")
    original_oid = ref(repository.checkout, "refs/heads/develop")
    add_remote_commit(repository)

    status, stdout, stderr = run_sync(home)

    assert status == 0
    assert stdout == ""
    assert stderr == ""
    assert ref(repository.checkout, "refs/heads/develop") == original_oid


def test_reports_fetch_failure(tmp_path: Path) -> None:
    home = tmp_path / "home"
    (home / "src").mkdir(parents=True)
    repository = make_repository(home, tmp_path, "repo", "main")
    with Repo(str(repository.checkout)) as repo:
        config = repo.get_config()
        config.set(
            (b"remote", b"origin"),
            b"url",
            str(tmp_path / "missing.git").encode(),
        )
        config.write_to_path()

    status, _, stderr = run_sync(home)

    assert status == 1
    assert "fetch from origin failed" in stderr
