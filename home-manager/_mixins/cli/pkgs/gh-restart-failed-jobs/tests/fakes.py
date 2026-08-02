from dataclasses import dataclass, field

from gh_restart_failed_jobs.api import GitHubApi
from gh_restart_failed_jobs.errors import RestartError
from gh_restart_failed_jobs.model import PullRequest


@dataclass
class FakeGitHubApi(GitHubApi):
    login: str = "booxter"
    pull_requests: tuple[PullRequest, ...] = ()
    runs: dict[str, tuple[int, ...]] = field(default_factory=dict)
    failing_labels: set[str] = field(default_factory=set)
    search_error: RestartError | None = None
    authenticated_hosts: list[str] = field(default_factory=list)
    searches: list[tuple[str, str]] = field(default_factory=list)
    checked: list[str] = field(default_factory=list)
    reruns: list[tuple[str, int]] = field(default_factory=list)

    def authenticated_login(self, host: str) -> str:
        self.authenticated_hosts.append(host)
        return self.login

    def open_pull_requests(self, host: str, owner: str) -> tuple[PullRequest, ...]:
        self.searches.append((host, owner))
        if self.search_error:
            raise self.search_error
        return self.pull_requests

    def failed_actions_run_ids(self, pull_request: PullRequest) -> tuple[int, ...]:
        self.checked.append(pull_request.label)
        return self.runs.get(pull_request.label, ())

    def rerun_failed_jobs(self, pull_request: PullRequest, run_id: int) -> None:
        self.reruns.append((pull_request.label, run_id))
        if pull_request.label in self.failing_labels:
            raise RestartError("rerun failed")
