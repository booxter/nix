from __future__ import annotations

from collections.abc import Mapping, Sequence
from dataclasses import dataclass, field
from pathlib import Path

import pytest
from git_command_runner import GitResult

from pki_rotation.askpass import response
from pki_rotation.errors import RotationError
from pki_rotation.models import CheckoutRequest
from pki_rotation.repository import GitRepository, authenticated_git_environment


@dataclass
class RecordingGit:
    results: list[GitResult] = field(default_factory=list)
    calls: list[tuple[list[str], Path | None]] = field(default_factory=list)

    def run(
        self,
        arguments: Sequence[str],
        *,
        repository: Path | None = None,
    ) -> GitResult:
        self.calls.append((list(arguments), repository))
        return self.results.pop(0) if self.results else GitResult(0, "", "")


def test_git_repository_uses_force_with_lease_and_scopes_commits(tmp_path: Path) -> None:
    git = RecordingGit(results=[GitResult(0, "", "")] * 8)
    repository = GitRepository(git)
    checkout = tmp_path / "checkout"

    repository.clone(CheckoutRequest("https://github.com/owner/repo.git", "master", checkout))
    repository.create_branch(checkout, "ci/pki-rotate")
    repository.commit_secrets(
        checkout,
        author_name="PKI Bot",
        author_email="pki@example.com",
    )
    repository.push_branch(checkout, "ci/pki-rotate")

    commands = [call[0] for call in git.calls]
    assert commands[1] == [
        "clone",
        "--branch",
        "master",
        "--single-branch",
        "--",
        "https://github.com/owner/repo.git",
        str(checkout),
    ]
    assert ["add", "--", "secrets"] in commands
    assert commands[-1] == [
        "push",
        "--force-with-lease",
        "origin",
        "HEAD:refs/heads/ci/pki-rotate",
    ]


def test_git_failures_have_operation_context() -> None:
    repository = GitRepository(RecordingGit([GitResult(1, "", "bad ref")]))

    with pytest.raises(RotationError, match="invalid Git branch master failed: bad ref"):
        repository.clone(CheckoutRequest("url", "master", Path("/tmp/repo")))


def test_has_secret_changes_uses_porcelain_output(tmp_path: Path) -> None:
    changed = GitRepository(RecordingGit([GitResult(0, " M secrets/main/pki.yaml\n", "")]))
    clean = GitRepository(RecordingGit([GitResult(0, "", "")]))

    assert changed.has_secret_changes(tmp_path)
    assert not clean.has_secret_changes(tmp_path)


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
