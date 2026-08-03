import io
import os
import subprocess
from dataclasses import dataclass
from pathlib import Path

from sync_repo.cli import main
from sync_repo.git import (
    RepositorySpec,
    RepositorySynchronizer,
    SubprocessGitRunner,
    repository_specs,
)


@dataclass(frozen=True)
class RepositoryFixture:
    remote: Path
    seed: Path
    checkout: Path
    branch: str = "master"

    @property
    def spec(self) -> RepositorySpec:
        return RepositorySpec("dotfiles", str(self.remote), self.checkout)


def git_environment() -> dict[str, str]:
    environment = os.environ.copy()
    environment.update(
        {
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_CONFIG_SYSTEM": os.devnull,
            "GIT_TERMINAL_PROMPT": "0",
        }
    )
    return environment


def run_git(
    repository: Path | None,
    *arguments: str,
    check: bool = True,
) -> subprocess.CompletedProcess[str]:
    command = ["git"]
    if repository is not None:
        command.extend(["-C", str(repository)])
    command.extend(arguments)
    return subprocess.run(
        command,
        check=check,
        capture_output=True,
        encoding="utf-8",
        errors="replace",
        env=git_environment(),
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


def repository_fixture(tmp_path: Path) -> RepositoryFixture:
    remote = tmp_path / "remote.git"
    seed = tmp_path / "seed"
    checkout = tmp_path / "home" / ".priv-bin"
    run_git(None, "init", "--bare", "--initial-branch=master", str(remote))
    run_git(None, "init", "--initial-branch=master", str(seed))
    configure_repository(seed)
    commit_file(seed, "value", "base\n", "base")
    run_git(seed, "remote", "add", "origin", str(remote))
    fixture = RepositoryFixture(remote, seed, checkout)
    push(fixture)
    return fixture


def invoke(
    fixture: RepositoryFixture,
    name: str = "dotfiles",
) -> tuple[int, str, str]:
    stdout = io.StringIO()
    stderr = io.StringIO()
    status = main(
        [name],
        specs={"dotfiles": fixture.spec},
        synchronizer=RepositorySynchronizer(SubprocessGitRunner(environment=git_environment())),
        stdout=stdout,
        stderr=stderr,
    )
    return status, stdout.getvalue(), stderr.getvalue()


def remote_head(fixture: RepositoryFixture) -> str:
    return run_git(fixture.remote, "rev-parse", "refs/heads/master").stdout.strip()


def local_head(fixture: RepositoryFixture) -> str:
    return run_git(fixture.checkout, "rev-parse", "HEAD").stdout.strip()


def test_clones_missing_repository(tmp_path: Path) -> None:
    fixture = repository_fixture(tmp_path)

    status, stdout, stderr = invoke(fixture)

    assert status == 0
    assert stderr == ""
    assert f"cloned dotfiles into {fixture.checkout}" in stdout
    assert local_head(fixture) == remote_head(fixture)


def test_rebases_incoming_commits_and_pushes_local_commits(tmp_path: Path) -> None:
    fixture = repository_fixture(tmp_path)
    assert invoke(fixture)[0] == 0
    configure_repository(fixture.checkout)
    commit_file(fixture.seed, "remote", "remote\n", "remote")
    push(fixture)
    commit_file(fixture.checkout, "local", "local\n", "local")

    status, stdout, stderr = invoke(fixture)

    assert status == 0
    assert stderr == ""
    assert f"pushed dotfiles from {fixture.checkout}" in stdout
    assert local_head(fixture) == remote_head(fixture)
    message = run_git(fixture.remote, "show", "--no-patch", "--format=%s", "HEAD")
    assert message.stdout.strip() == "local"


def test_leaves_failed_rebase_for_manual_resolution(tmp_path: Path) -> None:
    fixture = repository_fixture(tmp_path)
    assert invoke(fixture)[0] == 0
    configure_repository(fixture.checkout)
    commit_file(fixture.seed, "value", "remote\n", "remote")
    push(fixture)
    commit_file(fixture.checkout, "value", "local\n", "local")

    status, _, stderr = invoke(fixture)

    assert status == 1
    assert f"rebase failed in {fixture.checkout}; resolve it there manually" in stderr
    assert (fixture.checkout / ".git" / "rebase-merge").exists()


def test_reports_up_to_date_repository(tmp_path: Path) -> None:
    fixture = repository_fixture(tmp_path)
    assert invoke(fixture)[0] == 0
    assert invoke(fixture)[0] == 0

    status, stdout, stderr = invoke(fixture)

    assert status == 0
    assert stderr == ""
    assert f"dotfiles is up to date in {fixture.checkout}" in stdout


def test_pushes_a_new_local_branch_and_sets_its_upstream(tmp_path: Path) -> None:
    fixture = repository_fixture(tmp_path)
    assert invoke(fixture)[0] == 0
    run_git(fixture.checkout, "switch", "--create", "personal")

    status, stdout, stderr = invoke(fixture)

    assert status == 0
    assert stderr == ""
    assert f"pushed dotfiles from {fixture.checkout}" in stdout
    personal = run_git(fixture.remote, "rev-parse", "refs/heads/personal")
    assert personal.stdout.strip() == local_head(fixture)
    remote = run_git(fixture.checkout, "config", "branch.personal.remote")
    merge = run_git(fixture.checkout, "config", "branch.personal.merge")
    assert remote.stdout.strip() == "origin"
    assert merge.stdout.strip() == "refs/heads/personal"


def test_reports_clone_and_fetch_failures(tmp_path: Path) -> None:
    fixture = repository_fixture(tmp_path)
    fixture = RepositoryFixture(tmp_path / "missing.git", fixture.seed, fixture.checkout)

    clone_status, _, clone_stderr = invoke(fixture)

    assert clone_status == 1
    assert "clone failed:" in clone_stderr

    fetch_root = tmp_path / "fetch"
    fetch_root.mkdir()
    fixture = repository_fixture(fetch_root)
    assert invoke(fixture)[0] == 0
    run_git(
        fixture.checkout,
        "remote",
        "set-url",
        "origin",
        str(tmp_path / "gone.git"),
    )

    fetch_status, _, fetch_stderr = invoke(fixture)

    assert fetch_status == 1
    assert "fetch from origin failed:" in fetch_stderr


def test_rejects_unknown_repository_names(tmp_path: Path) -> None:
    fixture = repository_fixture(tmp_path)

    for name in ("unknown", "notes", "vault"):
        status, _, stderr = invoke(fixture, name)
        assert status == 2
        assert f"unknown repository: {name}" in stderr


def test_rejects_non_repository_and_detached_head(tmp_path: Path) -> None:
    fixture = repository_fixture(tmp_path)
    fixture.checkout.mkdir(parents=True)

    status, _, stderr = invoke(fixture)

    assert status == 1
    assert f"dotfiles is not a Git repository: {fixture.checkout}" in stderr

    fixture.checkout.rmdir()
    assert invoke(fixture)[0] == 0
    run_git(fixture.checkout, "switch", "--detach", local_head(fixture))

    detached_status, _, detached_stderr = invoke(fixture)

    assert detached_status == 1
    assert f"detached HEAD in {fixture.checkout}" in detached_stderr


def test_repository_paths_follow_environment(tmp_path: Path) -> None:
    home = tmp_path / "home"

    defaults = repository_specs(home, {})
    xdg = repository_specs(home, {"XDG_DATA_HOME": str(tmp_path / "data")})
    explicit = repository_specs(
        home,
        {"PASSWORD_STORE_DIR": str(tmp_path / "passwords")},
    )

    assert defaults["gmailctl"].path == home / ".gmailctl"
    assert defaults["dotfiles"].path == home / ".priv-bin"
    assert defaults["pass"].path == home / ".local" / "share" / "password-store"
    assert xdg["pass"].path == tmp_path / "data" / "password-store"
    assert explicit["pass"].path == tmp_path / "passwords"
