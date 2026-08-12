import re
from collections.abc import Callable, Iterable
from dataclasses import dataclass
from itertools import islice
from typing import Final, Protocol

from github import Auth, Github
from github.GithubException import GithubException

from gh_restart_failed_jobs.auth import TokenProvider
from gh_restart_failed_jobs.errors import RestartError
from gh_restart_failed_jobs.model import CheckRun, PullRequest, RepositoryRef

FAILED_CONCLUSIONS: Final = frozenset(
    {
        "action_required",
        "cancelled",
        "failure",
        "stale",
        "startup_failure",
        "timed_out",
    }
)
RUN_ID_PATTERN: Final = re.compile(r"/actions/runs/([0-9]+)(?:/|$)")


class GitHubApi(Protocol):
    def authenticated_login(self, host: str) -> str: ...

    def open_pull_requests(self, host: str, owner: str) -> tuple[PullRequest, ...]: ...

    def failed_actions_run_ids(self, pull_request: PullRequest) -> tuple[int, ...]: ...

    def rerun_failed_jobs(self, pull_request: PullRequest, run_id: int) -> None: ...


class GitHubClientFactory(Protocol):
    def create(self, *, token: str, base_url: str, timeout: int) -> Github: ...


@dataclass(frozen=True)
class PyGithubClientFactory:
    def create(self, *, token: str, base_url: str, timeout: int) -> Github:
        return Github(auth=Auth.Token(token), base_url=base_url, timeout=timeout)


def actions_run_ids(checks: Iterable[CheckRun]) -> tuple[int, ...]:
    run_ids: set[int] = set()
    for check in checks:
        if check.conclusion not in FAILED_CONCLUSIONS or not check.details_url:
            continue
        match = RUN_ID_PATTERN.search(check.details_url)
        if match:
            run_ids.add(int(match.group(1)))
    return tuple(sorted(run_ids))


def api_url(host: str) -> str:
    if host == "github.com":
        return "https://api.github.com"
    return f"https://{host}/api/v3"


@dataclass(frozen=True)
class PyGithubApi:
    tokens: TokenProvider
    timeout_seconds: int = 30
    search_limit: int = 1000
    base_url_for_host: Callable[[str], str] = api_url
    clients: GitHubClientFactory = PyGithubClientFactory()

    def _client(self, host: str) -> Github:
        return self.clients.create(
            token=self.tokens.token(host),
            base_url=self.base_url_for_host(host),
            timeout=self.timeout_seconds,
        )

    def authenticated_login(self, host: str) -> str:
        try:
            with self._client(host) as client:
                return client.get_user().login
        except GithubException as error:
            raise self._operation_error(error) from error

    def open_pull_requests(self, host: str, owner: str) -> tuple[PullRequest, ...]:
        try:
            with self._client(host) as client:
                issues = islice(
                    client.search_issues(
                        f"is:pr is:open user:{owner}",
                        sort="updated",
                        order="desc",
                    ),
                    self.search_limit,
                )
                return tuple(
                    PullRequest(
                        repository=RepositoryRef(host, issue.repository.full_name),
                        number=issue.number,
                        title=issue.title,
                        url=issue.html_url,
                    )
                    for issue in issues
                )
        except GithubException as error:
            raise self._operation_error(error) from error

    def failed_actions_run_ids(self, pull_request: PullRequest) -> tuple[int, ...]:
        try:
            with self._client(pull_request.repository.host) as client:
                repository = client.get_repo(pull_request.repository.name_with_owner)
                pull = repository.get_pull(pull_request.number)
                checks = repository.get_commit(pull.head.sha).get_check_runs()
                return actions_run_ids(
                    CheckRun(check.conclusion, check.details_url) for check in checks
                )
        except GithubException as error:
            raise self._operation_error(error) from error

    def rerun_failed_jobs(self, pull_request: PullRequest, run_id: int) -> None:
        try:
            with self._client(pull_request.repository.host) as client:
                repository = client.get_repo(pull_request.repository.name_with_owner)
                if not repository.get_workflow_run(run_id).rerun_failed_jobs():
                    raise RestartError(f"GitHub did not accept workflow run {run_id}")
        except GithubException as error:
            raise self._operation_error(error) from error

    @staticmethod
    def _operation_error(error: GithubException) -> RestartError:
        return RestartError(f"GitHub API request failed with status {error.status}: {error.data}")
