import io

from gh_restart_failed_jobs.cli import main, pull_request_from_url
from gh_restart_failed_jobs.errors import RestartError
from gh_restart_failed_jobs.model import PullRequest, RepositoryRef
from fakes import FakeGitHubApi


def pull_request(repository: str, number: int, title: str = "") -> PullRequest:
    return PullRequest(
        RepositoryRef("github.com", repository),
        number,
        title=title,
        url=f"https://github.com/{repository}/pull/{number}",
    )


def invoke(
    arguments: list[str],
    api: FakeGitHubApi,
    *,
    answer: str = "",
) -> tuple[int, str, str]:
    stdout = io.StringIO()
    stderr = io.StringIO()
    status = main(
        arguments,
        api=api,
        stdin=io.StringIO(answer),
        stdout=stdout,
        stderr=stderr,
    )
    return status, stdout.getvalue(), stderr.getvalue()


def test_parses_pull_request_url_with_suffix() -> None:
    parsed = pull_request_from_url("https://github.com/acme/widgets/pull/42/files?diff=split")

    assert parsed == PullRequest(
        RepositoryRef("github.com", "acme/widgets"),
        42,
        url="https://github.com/acme/widgets/pull/42",
    )


def test_restarts_each_distinct_failed_workflow_run() -> None:
    api = FakeGitHubApi(runs={"acme/widgets#42": (101, 202)})

    status, stdout, stderr = invoke(["https://github.com/acme/widgets/pull/42/files"], api)

    assert status == 0
    assert "restarted failed jobs in 2 workflow run(s)" in stdout
    assert stderr == ""
    assert api.reruns == [("acme/widgets#42", 101), ("acme/widgets#42", 202)]


def test_accepts_qualified_and_unqualified_repositories() -> None:
    qualified = FakeGitHubApi(runs={"booxter/nix#42": (101,)})
    unqualified = FakeGitHubApi(runs={"booxter/nix#42": (101,)})

    assert invoke(["booxter/nix", "42"], qualified)[0] == 0
    assert invoke(["nix", "42"], unqualified)[0] == 0
    assert qualified.authenticated_hosts == []
    assert unqualified.authenticated_hosts == ["github.com"]


def test_reports_when_no_actions_runs_failed() -> None:
    status, stdout, _ = invoke(["https://github.com/acme/widgets/pull/42"], FakeGitHubApi())

    assert status == 0
    assert "no failed GitHub Actions jobs found" in stdout


def test_lists_confirms_and_processes_all_pull_requests() -> None:
    pulls = (
        pull_request("booxter/nix", 42, "Improve the Nix configuration"),
        pull_request("booxter/dotfiles", 7, "Refresh shell aliases"),
    )
    api = FakeGitHubApi(
        pull_requests=pulls,
        runs={pull.label: (101,) for pull in pulls},
    )

    status, stdout, stderr = invoke(["--all"], api, answer="yes\n")

    assert status == 0
    assert "found 2 open pull request(s) for booxter" in stdout
    assert "1. booxter/nix#42 Improve the Nix configuration" in stdout
    assert "[2/2] processing booxter/dotfiles#7" in stdout
    assert "processed 2 pull request(s): 2 succeeded, 0 failed" in stdout
    assert "Process all 2 open pull request(s)? [y/N]" in stderr
    assert api.searches == [("github.com", "booxter")]


def test_does_not_process_all_without_confirmation() -> None:
    pull = pull_request("booxter/nix", 42)
    api = FakeGitHubApi(pull_requests=(pull,), runs={pull.label: (101,)})

    status, stdout, _ = invoke(["--all"], api, answer="no\n")

    assert status == 0
    assert "cancelled" in stdout
    assert api.checked == []


def test_reports_empty_or_failed_pull_request_search() -> None:
    status, stdout, _ = invoke(["--all"], FakeGitHubApi())
    failed_status, _, stderr = invoke(
        ["--all"], FakeGitHubApi(search_error=RestartError("search failed"))
    )

    assert status == 0
    assert "no open pull requests found for booxter" in stdout
    assert failed_status == 1
    assert "search failed" in stderr


def test_continues_batch_after_one_pull_request_fails() -> None:
    first = pull_request("booxter/nix", 42)
    second = pull_request("booxter/dotfiles", 7)
    api = FakeGitHubApi(
        pull_requests=(first, second),
        runs={first.label: (101,), second.label: (202,)},
        failing_labels={first.label},
    )

    status, stdout, stderr = invoke(["--all"], api, answer="y\n")

    assert status == 1
    assert "[2/2] processing booxter/dotfiles#7" in stdout
    assert "processed 2 pull request(s): 1 succeeded, 1 failed" in stdout
    assert "booxter/nix#42 failed" in stderr
    assert api.reruns[-1] == ("booxter/dotfiles#7", 202)


def test_rejects_invalid_argument_forms() -> None:
    for arguments, expected in (
        ([], "expected a pull request URL"),
        (["acme/widgets#42"], "not a GitHub pull request URL"),
        (["acme/widgets", "nope"], "not a pull request number"),
        (["too/many/slashes", "42"], "not a repository name"),
    ):
        status, _, stderr = invoke(arguments, FakeGitHubApi())
        assert status == 2
        assert expected in stderr
        assert "usage: gh-restart-failed-jobs" in stderr
