import os
import subprocess
from dataclasses import dataclass
from io import StringIO
from pathlib import Path

from sync_git_mains.cli import main


@dataclass(frozen=True)
class RepositoryFixture:
    remote: Path
    seed: Path
    checkout: Path
    branch: str


def run_git(
    repository: Path | None,
    *arguments: str,
    check: bool = True,
) -> subprocess.CompletedProcess[str]:
    command = ["git"]
    if repository is not None:
        command.extend(["-C", str(repository)])
    command.extend(arguments)
    environment = os.environ.copy()
    environment.update(
        {
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_CONFIG_SYSTEM": os.devnull,
            "GIT_TERMINAL_PROMPT": "0",
        }
    )
    return subprocess.run(
        command,
        check=check,
        capture_output=True,
        encoding="utf-8",
        errors="replace",
        env=environment,
    )


def configure_repository(repository: Path) -> None:
    run_git(repository, "config", "user.name", "Test")
    run_git(repository, "config", "user.email", "test@example.com")


def commit_file(repository: Path, filename: str, content: str, message: str) -> str:
    (repository / filename).write_text(content, encoding="utf-8")
    run_git(repository, "add", filename)
    run_git(repository, "commit", "--message", message)
    return run_git(repository, "rev-parse", "HEAD").stdout.strip()


def push(repository: RepositoryFixture) -> None:
    reference = f"refs/heads/{repository.branch}"
    run_git(
        repository.seed,
        "push",
        "origin",
        f"{reference}:{reference}",
    )


def make_repository(home: Path, root: Path, name: str, branch: str) -> RepositoryFixture:
    remote = root / f"{name}.git"
    seed = root / f"{name}-seed"
    checkout = home / "src" / name
    run_git(None, "init", "--bare", f"--initial-branch={branch}", str(remote))
    run_git(None, "init", f"--initial-branch={branch}", str(seed))
    configure_repository(seed)
    commit_file(seed, "value", "base\n", "base")
    run_git(seed, "remote", "add", "origin", str(remote))
    repository = RepositoryFixture(remote, seed, checkout, branch)
    push(repository)
    run_git(None, "clone", str(remote), str(checkout))
    configure_repository(checkout)
    return repository


def add_remote_commit(repository: RepositoryFixture, filename: str = "remote") -> str:
    commit = commit_file(repository.seed, filename, "remote\n", "remote")
    push(repository)
    return commit


def run_sync(home: Path, arguments: list[str] | None = None) -> tuple[int, str, str]:
    stdout = StringIO()
    stderr = StringIO()
    status = main(arguments, home=home, stdout=stdout, stderr=stderr)
    return status, stdout.getvalue(), stderr.getvalue()


def ref(repository: Path, name: str) -> str:
    return run_git(repository, "rev-parse", name).stdout.strip()


def current_branch(repository: Path) -> str | None:
    result = run_git(repository, "symbolic-ref", "--quiet", "HEAD", check=False)
    return result.stdout.strip() if result.returncode == 0 else None


def test_discovers_and_fast_forwards_checked_out_main_branches(tmp_path: Path) -> None:
    home = tmp_path / "home"
    (home / "src").mkdir(parents=True)
    main = make_repository(home, tmp_path, "main-repo", "main")
    master = make_repository(home, tmp_path, "master-repo", "master")
    (home / "src" / "not-a-repository").mkdir()
    (home / "src" / "not-a-directory").write_text("ignored\n", encoding="utf-8")
    run_git(None, "init", "--initial-branch=main", str(home / "src" / "no-origin"))
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
    feature_oid = ref(repository.checkout, "refs/heads/main")
    run_git(repository.checkout, "switch", "--create", "feature")
    remote_oid = add_remote_commit(repository)

    status, _, stderr = run_sync(home, [str(home / "src")])

    assert status == 0
    assert stderr == ""
    assert current_branch(repository.checkout) == "refs/heads/feature"
    assert ref(repository.checkout, "HEAD") == feature_oid
    assert ref(repository.checkout, "refs/heads/main") == remote_oid


def test_does_not_create_missing_local_default_branch(tmp_path: Path) -> None:
    home = tmp_path / "home"
    (home / "src").mkdir(parents=True)
    repository = make_repository(home, tmp_path, "repo", "main")
    run_git(repository.checkout, "switch", "--create", "feature")
    run_git(repository.checkout, "branch", "--delete", "--force", "main")
    add_remote_commit(repository)

    status, _, stderr = run_sync(home)

    assert status == 0
    assert stderr == ""
    missing = run_git(
        repository.checkout,
        "show-ref",
        "--verify",
        "--quiet",
        "refs/heads/main",
        check=False,
    )
    assert missing.returncode == 1


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
    run_git(
        repository.checkout,
        "remote",
        "set-url",
        "origin",
        str(tmp_path / "missing.git"),
    )

    status, _, stderr = run_sync(home)

    assert status == 1
    assert "fetch from origin failed" in stderr
