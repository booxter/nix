import io
from dataclasses import dataclass
from pathlib import Path

from dulwich import porcelain
from dulwich.objects import Commit
from dulwich.refs import Ref
from dulwich.repo import Repo

from sync_repo.cli import main
from sync_repo.git import RepositorySpec, repository_specs

IDENTITY = b"Test <test@example.com>"


@dataclass(frozen=True)
class RepositoryFixture:
    remote: Path
    seed: Path
    checkout: Path
    branch: str = "master"

    @property
    def spec(self) -> RepositorySpec:
        return RepositorySpec("dotfiles", str(self.remote), self.checkout)


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
        outstream=io.BytesIO(),
        errstream=io.BytesIO(),
    )


def repository_fixture(tmp_path: Path) -> RepositoryFixture:
    remote = tmp_path / "remote.git"
    seed = tmp_path / "seed"
    checkout = tmp_path / "home" / ".priv-bin"
    reference = Ref(b"refs/heads/master")
    with porcelain.init(remote, bare=True) as bare:
        bare.refs.set_symbolic_ref(Ref(b"HEAD"), reference)
    with porcelain.init(seed) as local:
        local.refs.set_symbolic_ref(Ref(b"HEAD"), reference)
    commit_file(seed, "value", "base\n", "base")
    porcelain.remote_add(seed, "origin", str(remote))
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
        stdout=stdout,
        stderr=stderr,
    )
    return status, stdout.getvalue(), stderr.getvalue()


def remote_head(fixture: RepositoryFixture) -> bytes:
    with Repo(str(fixture.remote)) as repository:
        return repository.refs[Ref(b"refs/heads/master")]


def local_head(fixture: RepositoryFixture) -> bytes:
    with Repo(str(fixture.checkout)) as repository:
        return repository.head()


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
    commit_file(fixture.seed, "remote", "remote\n", "remote")
    push(fixture)
    commit_file(fixture.checkout, "local", "local\n", "local")

    status, stdout, stderr = invoke(fixture)

    assert status == 0
    assert stderr == ""
    assert f"pushed dotfiles from {fixture.checkout}" in stdout
    assert local_head(fixture) == remote_head(fixture)
    with Repo(str(fixture.remote)) as repository:
        commit = repository[repository.head()]
        assert isinstance(commit, Commit)
        assert commit.message == b"local"


def test_leaves_failed_rebase_for_manual_resolution(tmp_path: Path) -> None:
    fixture = repository_fixture(tmp_path)
    assert invoke(fixture)[0] == 0
    commit_file(fixture.seed, "value", "remote\n", "remote")
    push(fixture)
    commit_file(fixture.checkout, "value", "local\n", "local")

    status, _, stderr = invoke(fixture)

    assert status == 1
    assert f"rebase failed in {fixture.checkout}; resolve it there manually" in stderr
    with Repo(str(fixture.checkout)) as repository:
        assert repository.get_rebase_state_manager().exists()


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
    porcelain.switch(fixture.checkout, "master", create="personal")

    status, stdout, stderr = invoke(fixture)

    assert status == 0
    assert stderr == ""
    assert f"pushed dotfiles from {fixture.checkout}" in stdout
    with Repo(str(fixture.remote)) as repository:
        assert repository.refs[Ref(b"refs/heads/personal")] == local_head(fixture)
    with Repo(str(fixture.checkout)) as repository:
        config = repository.get_config_stack()
        assert config.get((b"branch", b"personal"), b"remote") == b"origin"
        assert config.get((b"branch", b"personal"), b"merge") == b"refs/heads/personal"


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
    with Repo(str(fixture.checkout)) as repository:
        config = repository.get_config()
        config.set((b"remote", b"origin"), b"url", str(tmp_path / "gone.git").encode())
        config.write_to_path()

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
    porcelain.switch(fixture.checkout, local_head(fixture), detach=True)

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
