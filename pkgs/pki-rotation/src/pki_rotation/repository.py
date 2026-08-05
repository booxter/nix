from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol

from git_command_runner import GitResult, GitRunner, SubprocessGitRunner, stderr_suffix

from .errors import RotationError
from .models import CheckoutRequest


class Repository(Protocol):
    def clone(self, request: CheckoutRequest) -> None: ...

    def create_branch(self, repo_root: Path, branch: str) -> None: ...

    def has_secret_changes(self, repo_root: Path) -> bool: ...

    def commit_secrets(self, repo_root: Path, *, author_name: str, author_email: str) -> None: ...

    def push_branch(self, repo_root: Path, branch: str) -> None: ...


class RepositoryFactory(Protocol):
    def create(self, environment: Mapping[str, str] | None = None) -> Repository: ...


@dataclass(frozen=True)
class GitRepositoryFactory:
    def create(self, environment: Mapping[str, str] | None = None) -> Repository:
        return GitRepository(SubprocessGitRunner(environment=environment))


@dataclass(frozen=True)
class GitRepository:
    runner: GitRunner

    @staticmethod
    def _require(result: GitResult, operation: str) -> str:
        if result.returncode != 0:
            raise RotationError(f"{operation} failed{stderr_suffix(result)}")
        return result.stdout

    def _validate_branch(self, branch: str) -> None:
        self._require(
            self.runner.run(["check-ref-format", "--branch", branch]),
            f"invalid Git branch {branch}",
        )

    def clone(self, request: CheckoutRequest) -> None:
        self._validate_branch(request.branch)
        request.target.parent.mkdir(parents=True, exist_ok=True)
        self._require(
            self.runner.run(
                [
                    "clone",
                    "--branch",
                    request.branch,
                    "--single-branch",
                    "--",
                    request.repo_url,
                    str(request.target),
                ]
            ),
            "Git clone",
        )

    def create_branch(self, repo_root: Path, branch: str) -> None:
        self._validate_branch(branch)
        self._require(
            self.runner.run(["switch", "--create", branch], repository=repo_root),
            "Git branch creation",
        )

    def has_secret_changes(self, repo_root: Path) -> bool:
        output = self._require(
            self.runner.run(["status", "--porcelain", "--", "secrets"], repository=repo_root),
            "Git status",
        )
        return bool(output.strip())

    def commit_secrets(self, repo_root: Path, *, author_name: str, author_email: str) -> None:
        self._require(
            self.runner.run(["add", "--", "secrets"], repository=repo_root),
            "Git add",
        )
        self._require(
            self.runner.run(
                [
                    "-c",
                    f"user.name={author_name}",
                    "-c",
                    f"user.email={author_email}",
                    "commit",
                    "--message",
                    "chore: rotate internal PKI leaf certs",
                ],
                repository=repo_root,
            ),
            "Git commit",
        )

    def push_branch(self, repo_root: Path, branch: str) -> None:
        self._validate_branch(branch)
        self._require(
            self.runner.run(
                [
                    "push",
                    "--force-with-lease",
                    "origin",
                    f"HEAD:refs/heads/{branch}",
                ],
                repository=repo_root,
            ),
            "Git push",
        )


def authenticated_git_environment(
    environment: Mapping[str, str],
    *,
    token_file: Path,
    askpass_program: Path,
) -> dict[str, str]:
    return {
        **environment,
        "GIT_ASKPASS": str(askpass_program),
        "GIT_ASKPASS_REQUIRE": "force",
        "GIT_TERMINAL_PROMPT": "0",
        "PKI_ROTATION_GITHUB_TOKEN_FILE": str(token_file.resolve()),
    }
