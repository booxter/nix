from dataclasses import dataclass, field

import pytest
from github import Github
from github.GithubException import GithubException

from gh_restart_failed_jobs.api import (
    PyGithubApi,
    PyGithubClientFactory,
    actions_run_ids,
    api_url,
)
from gh_restart_failed_jobs.errors import RestartError
from gh_restart_failed_jobs.model import CheckRun


class StaticTokenProvider:
    def token(self, host: str) -> str:
        return f"token-for-{host}"


@dataclass(frozen=True)
class FakeUser:
    login: str = "booxter"


@dataclass(frozen=True)
class FakeRepositorySummary:
    full_name: str = "acme/widgets"


@dataclass(frozen=True)
class FakeIssue:
    repository: FakeRepositorySummary = FakeRepositorySummary()
    number: int = 42
    title: str = "Improve widgets"
    html_url: str = "https://github.com/acme/widgets/pull/42"


@dataclass(frozen=True)
class FakeCheck:
    conclusion: str
    details_url: str


@dataclass(frozen=True)
class FakeCommit:
    def get_check_runs(self) -> tuple[FakeCheck, ...]:
        return (
            FakeCheck(
                "failure",
                "https://github.com/acme/widgets/actions/runs/101/job/1001",
            ),
            FakeCheck(
                "success",
                "https://github.com/acme/widgets/actions/runs/202/job/2001",
            ),
        )


@dataclass(frozen=True)
class FakePullHead:
    sha: str = "head-sha"


@dataclass(frozen=True)
class FakePull:
    head: FakePullHead = FakePullHead()


@dataclass
class FakeWorkflowRun:
    accepted: bool = True
    calls: int = 0

    def rerun_failed_jobs(self) -> bool:
        self.calls += 1
        return self.accepted


@dataclass
class FakeRepository:
    workflow_run: FakeWorkflowRun

    def get_pull(self, number: int) -> FakePull:
        assert number == 42
        return FakePull()

    def get_commit(self, sha: str) -> FakeCommit:
        assert sha == "head-sha"
        return FakeCommit()

    def get_workflow_run(self, run_id: int) -> FakeWorkflowRun:
        assert run_id == 101
        return self.workflow_run


@dataclass
class FakeGithub(Github):
    workflow_run: FakeWorkflowRun
    failure: GithubException | None = None
    searches: list[tuple[str, str, str]] = field(default_factory=list)

    def __enter__(self) -> "FakeGithub":
        return self

    def __exit__(self, *args: object) -> None:
        pass

    def get_user(self) -> FakeUser:
        if self.failure:
            raise self.failure
        return FakeUser()

    def search_issues(self, query: str, *, sort: str, order: str) -> tuple[FakeIssue, ...]:
        self.searches.append((query, sort, order))
        return (FakeIssue(),)

    def get_repo(self, name: str) -> FakeRepository:
        assert name == "acme/widgets"
        return FakeRepository(self.workflow_run)


@dataclass
class FakeClientFactory:
    client: FakeGithub
    calls: list[tuple[str, str, int]] = field(default_factory=list)

    def create(self, *, token: str, base_url: str, timeout: int) -> FakeGithub:
        self.calls.append((token, base_url, timeout))
        return self.client


def test_extracts_distinct_failed_actions_run_ids() -> None:
    assert actions_run_ids(
        (
            CheckRun(
                "failure",
                "https://github.com/acme/widgets/actions/runs/101/job/1001",
            ),
            CheckRun(
                "timed_out",
                "https://github.com/acme/widgets/actions/runs/101/job/1002",
            ),
            CheckRun(
                "cancelled",
                "https://github.com/acme/widgets/actions/runs/202/job/2001",
            ),
            CheckRun("failure", "https://ci.example.com/build/303"),
            CheckRun(
                "success",
                "https://github.com/acme/widgets/actions/runs/404/job/4001",
            ),
            CheckRun("failure", None),
        )
    ) == (101, 202)


def test_selects_public_and_enterprise_api_urls() -> None:
    assert api_url("github.com") == "https://api.github.com"
    assert api_url("github.example.com") == "https://github.example.com/api/v3"


def test_pygithub_adapter_uses_native_api_objects() -> None:
    workflow_run = FakeWorkflowRun()
    client = FakeGithub(workflow_run)
    factory = FakeClientFactory(client)
    api = PyGithubApi(StaticTokenProvider(), clients=factory)

    assert api.authenticated_login("github.com") == "booxter"
    pull_requests = api.open_pull_requests("github.com", "booxter")
    assert len(pull_requests) == 1
    pull_request = pull_requests[0]
    assert pull_request.label == "acme/widgets#42"
    assert api.failed_actions_run_ids(pull_request) == (101,)
    api.rerun_failed_jobs(pull_request, 101)

    assert workflow_run.calls == 1
    assert client.searches == [("is:pr is:open user:booxter", "updated", "desc")]
    assert (
        factory.calls
        == [
            ("token-for-github.com", "https://api.github.com", 30),
        ]
        * 4
    )


def test_pygithub_adapter_translates_api_errors() -> None:
    client = FakeGithub(FakeWorkflowRun(), failure=GithubException(403, "forbidden"))
    api = PyGithubApi(
        StaticTokenProvider(),
        clients=FakeClientFactory(client),
    )

    with pytest.raises(RestartError, match="status 403"):
        api.authenticated_login("github.com")


def test_pygithub_adapter_rejects_unaccepted_rerun() -> None:
    client = FakeGithub(FakeWorkflowRun(accepted=False))
    api = PyGithubApi(
        StaticTokenProvider(),
        clients=FakeClientFactory(client),
    )
    pull_request = api.open_pull_requests("github.com", "booxter")[0]

    with pytest.raises(RestartError, match="did not accept workflow run 101"):
        api.rerun_failed_jobs(pull_request, 101)


def test_default_client_factory_builds_pygithub_client() -> None:
    client = PyGithubClientFactory().create(
        token="token",
        base_url="https://api.github.com",
        timeout=30,
    )

    assert isinstance(client, Github)
    client.close()
