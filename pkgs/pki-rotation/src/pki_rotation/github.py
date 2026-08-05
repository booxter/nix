from __future__ import annotations

from dataclasses import dataclass
from typing import Protocol

from github import Auth, Github
from github.GithubException import GithubException

from .errors import RotationError
from .models import PullRequest


class PullRequests(Protocol):
    def find_open(
        self,
        owner: str,
        repository: str,
        *,
        branch: str,
        base_branch: str,
    ) -> PullRequest | None: ...

    def create(
        self,
        owner: str,
        repository: str,
        *,
        branch: str,
        base_branch: str,
        title: str,
        body: str,
    ) -> PullRequest: ...


class PullRequestFactory(Protocol):
    def create(self, token: str) -> PullRequests: ...


@dataclass(frozen=True)
class GitHubPullRequestFactory:
    def create(self, token: str) -> PullRequests:
        return GitHubPullRequests(token)


@dataclass(frozen=True)
class GitHubPullRequests:
    token: str
    timeout_seconds: int = 30

    def _client(self) -> Github:
        return Github(auth=Auth.Token(self.token), timeout=self.timeout_seconds)

    @staticmethod
    def _error(error: GithubException) -> RotationError:
        return RotationError(f"GitHub API request failed with status {error.status}: {error.data}")

    def find_open(
        self,
        owner: str,
        repository: str,
        *,
        branch: str,
        base_branch: str,
    ) -> PullRequest | None:
        try:
            with self._client() as client:
                pulls = client.get_repo(f"{owner}/{repository}").get_pulls(
                    state="open",
                    head=f"{owner}:{branch}",
                    base=base_branch,
                )
                for pull in pulls:
                    return PullRequest(pull.html_url)
                return None
        except GithubException as error:
            raise self._error(error) from error

    def create(
        self,
        owner: str,
        repository: str,
        *,
        branch: str,
        base_branch: str,
        title: str,
        body: str,
    ) -> PullRequest:
        try:
            with self._client() as client:
                pull = client.get_repo(f"{owner}/{repository}").create_pull(
                    title=title,
                    body=body,
                    head=branch,
                    base=base_branch,
                )
                return PullRequest(pull.html_url)
        except GithubException as error:
            raise self._error(error) from error
