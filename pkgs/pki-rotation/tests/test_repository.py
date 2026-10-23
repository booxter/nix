from __future__ import annotations

from collections.abc import Mapping, Sequence
from dataclasses import dataclass, field
from pathlib import Path

import pytest
from git_command_runner import GitResult, SubprocessGitRunner
from pki_rotation.askpass import response
from pki_rotation.errors import RotationError
from pki_rotation.models import CheckoutRequest
from pki_rotation.repository import GitRepository, authenticated_git_environment


@dataclass
class FailingGit:
    results: list[GitResult] = field(default_factory=list)

    def run(
        self,
        arguments: Sequence[str],
        *,
        repository: Path | None = None,
    ) -> GitResult:
        return self.results.pop(0) if self.results else GitResult(0, "", "")


@pytest.mark.parametrize("existing_branch", [False, True])
@pytest.mark.parametrize("concurrent_update", [False, True])
def test_rotation_push_preserves_concurrent_changes(
    tmp_path: Path, existing_branch: bool, concurrent_update: bool
) -> None:
    runner = SubprocessGitRunner()

    def git(repo: Path, *arguments: str) -> str:
        result = runner.run(arguments, repository=repo)
        assert result.returncode == 0, result.stderr
        return result.stdout.strip()

    remote = tmp_path / "remote"
    remote.mkdir()
    git(remote, "init", "--bare", "--initial-branch=master")
    seed = tmp_path / "seed"
    seed.mkdir()
    git(seed, "init", "--initial-branch=master")
    git(seed, "config", "user.name", "PKI Bot")
    git(seed, "config", "user.email", "pki@example.com")
    git(seed, "commit", "--allow-empty", "-m", "Initial commit")
    git(seed, "remote", "add", "origin", str(remote))
    git(seed, "push", "origin", "master")
    branch = "ci/pki-rotate"
    if existing_branch:
        git(seed, "commit", "--allow-empty", "-m", "Previous rotation")
        git(seed, "push", "origin", f"HEAD:refs/heads/{branch}")

    repository = GitRepository(runner)
    checkout = tmp_path / "checkout"
    repository.clone(CheckoutRequest(str(remote), "master", checkout))
    repository.create_branch(checkout, branch)
    secrets = checkout / "secrets"
    secrets.mkdir()
    (secrets / "certificate").write_text("Renewed certificate\n")
    (checkout / "unrelated").write_text("Leave uncommitted\n")
    assert repository.has_secret_changes(checkout)
    repository.commit_secrets(checkout, author_name="PKI Bot", author_email="pki@example.com")
    assert not repository.has_secret_changes(checkout)
    assert git(checkout, "ls-tree", "--name-only", "HEAD") == "secrets"

    if concurrent_update:
        git(seed, "commit", "--allow-empty", "-m", "Concurrent rotation")
        git(seed, "push", "origin", f"HEAD:refs/heads/{branch}")
        with pytest.raises(RotationError, match="Git push failed"):
            repository.push_branch(checkout, branch)
        expected = git(seed, "rev-parse", "HEAD")
    else:
        repository.push_branch(checkout, branch)
        expected = git(checkout, "rev-parse", "HEAD")

    assert git(remote, "rev-parse", f"refs/heads/{branch}") == expected


def test_git_failures_have_operation_context() -> None:
    repository = GitRepository(FailingGit([GitResult(1, "", "bad ref")]))

    with pytest.raises(RotationError, match="invalid Git branch master failed: bad ref"):
        repository.clone(CheckoutRequest("url", "master", Path("/tmp/repo")))


def test_authenticated_environment_uses_fixed_askpass_program(tmp_path: Path) -> None:
    token_file = tmp_path / "token"
    askpass = Path("/nix/store/askpass/bin/pki-rotation-git-askpass")

    environment = authenticated_git_environment(
        {"PATH": "/bin"},
        token_file=token_file,
        askpass_program=askpass,
    )

    assert environment["PATH"] == "/bin"
    assert environment["GIT_ASKPASS"] == str(askpass)
    assert environment["GIT_TERMINAL_PROMPT"] == "0"
    assert environment["PKI_ROTATION_GITHUB_TOKEN_FILE"] == str(token_file.resolve())


def test_askpass_reads_token_without_embedding_shell(tmp_path: Path) -> None:
    token_file = tmp_path / "token"
    token_file.write_text("secret-token\n")
    environment: Mapping[str, str] = {"PKI_ROTATION_GITHUB_TOKEN_FILE": str(token_file)}

    assert response("Username for GitHub", environment) == "x-access-token"
    assert response("Password for GitHub", environment) == "secret-token"
    assert response("unknown prompt", environment) == ""
