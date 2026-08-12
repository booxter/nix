from dataclasses import dataclass, field
from collections.abc import Sequence

import pytest

from gh_restart_failed_jobs.auth import CommandResult, GhTokenProvider
from gh_restart_failed_jobs.errors import RestartError


@dataclass
class FakeRunner:
    result: CommandResult
    calls: list[tuple[str, ...]] = field(default_factory=list)

    def run(self, arguments: Sequence[str]) -> CommandResult:
        self.calls.append(tuple(arguments))
        return self.result


def test_prefers_environment_token() -> None:
    runner = FakeRunner(CommandResult(1, "", "must not run"))

    assert GhTokenProvider({"GH_TOKEN": " env-token "}, runner).token("github.com") == "env-token"
    assert runner.calls == []


def test_uses_enterprise_environment_token() -> None:
    runner = FakeRunner(CommandResult(1, "", "must not run"))

    assert (
        GhTokenProvider({"GH_ENTERPRISE_TOKEN": "enterprise"}, runner).token("github.example.com")
        == "enterprise"
    )
    assert runner.calls == []


def test_falls_back_to_gh_authentication() -> None:
    runner = FakeRunner(CommandResult(0, "token\n", ""))

    assert GhTokenProvider({}, runner).token("github.example.com") == "token"
    assert runner.calls == [("gh", "auth", "token", "--hostname", "github.example.com")]


def test_reports_gh_authentication_failure() -> None:
    runner = FakeRunner(CommandResult(1, "", "not logged in\n"))

    with pytest.raises(RestartError, match="not logged in"):
        GhTokenProvider({}, runner).token("github.com")
