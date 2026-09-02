from __future__ import annotations

from collections.abc import Sequence
from dataclasses import dataclass, field
from io import StringIO

from codex_mcp_login.app_server import ProbeError
from codex_mcp_login.login import LoginError
from codex_mcp_login.models import (
    REAUTHENTICATION_REQUIRED,
    ServerStartup,
    StartupStatus,
)
from codex_mcp_login.workflow import LoginWorkflow

ProbeResponse = tuple[ServerStartup, ...] | ProbeError


@dataclass
class FakeProbe:
    responses: list[ProbeResponse]
    calls: list[tuple[str, ...]] = field(default_factory=list)

    def probe(self, server_names: Sequence[str]) -> tuple[ServerStartup, ...]:
        self.calls.append(tuple(server_names))
        response = self.responses.pop(0)
        if isinstance(response, ProbeError):
            raise response
        return response


@dataclass
class FakeLogin:
    results: dict[str, int | LoginError]
    calls: list[str] = field(default_factory=list)

    def login(self, server_name: str) -> int:
        self.calls.append(server_name)
        result = self.results[server_name]
        if isinstance(result, LoginError):
            raise result
        return result


def ready(name: str) -> ServerStartup:
    return ServerStartup(name, StartupStatus.READY)


def reauthentication_required(name: str) -> ServerStartup:
    return ServerStartup(
        name,
        StartupStatus.FAILED,
        error="login required",
        failure_reason=REAUTHENTICATION_REQUIRED,
    )


def run_workflow(
    probe: FakeProbe,
    login: FakeLogin,
    servers: Sequence[str] = ("alpha", "beta"),
) -> tuple[int, str]:
    output = StringIO()
    result = LoginWorkflow(probe, login, output).run(servers)
    return result, output.getvalue()


def test_skips_ready_servers() -> None:
    status, output = run_workflow(
        FakeProbe([(ready("alpha"), ready("beta"))]),
        FakeLogin({}),
        ("alpha", "beta", "alpha"),
    )

    assert status == 0
    assert output == "Checking 2 MCP server(s)...\nalpha: ready\nbeta: ready\n"


def test_logs_in_sequentially_and_verifies_with_fresh_probe() -> None:
    probe = FakeProbe(
        [
            (ready("alpha"), reauthentication_required("beta"), reauthentication_required("gamma")),
            (ready("beta"), ready("gamma")),
        ]
    )
    login = FakeLogin({"beta": 0, "gamma": 0})

    status, output = run_workflow(probe, login, ("alpha", "beta", "gamma"))

    assert status == 0
    assert login.calls == ["beta", "gamma"]
    assert probe.calls == [("alpha", "beta", "gamma"), ("beta", "gamma")]
    assert "beta: opening OAuth login" in output
    assert "Verifying 2 repaired MCP server(s)" in output


def test_continues_after_login_failures_and_reports_them() -> None:
    probe = FakeProbe(
        [
            (reauthentication_required("alpha"), reauthentication_required("beta")),
            (ready("beta"),),
        ]
    )
    login = FakeLogin({"alpha": LoginError("could not execute codex"), "beta": 0})

    status, output = run_workflow(probe, login)

    assert status == 1
    assert login.calls == ["alpha", "beta"]
    assert "alpha: could not execute codex" in output


def test_reports_nonzero_login_and_verification_failure() -> None:
    probe = FakeProbe(
        [
            (reauthentication_required("alpha"), reauthentication_required("beta")),
            (ServerStartup("alpha", StartupStatus.FAILED, failure_reason="still broken"),),
        ]
    )
    login = FakeLogin({"alpha": 0, "beta": 4})

    status, output = run_workflow(probe, login)

    assert status == 1
    assert "beta: login failed with exit code 4" in output
    assert "alpha: verification failed: still broken" in output


def test_reports_startup_and_probe_failures() -> None:
    initial_failure = ServerStartup("alpha", StartupStatus.FAILED, error="network failed")
    status, output = run_workflow(FakeProbe([(initial_failure, ready("beta"))]), FakeLogin({}))
    assert status == 1
    assert "alpha: startup failed: network failed" in output

    status, output = run_workflow(FakeProbe([ProbeError("probe broke")]), FakeLogin({}))
    assert status == 1
    assert "error: probe broke" in output


def test_reports_verification_probe_failure() -> None:
    status, output = run_workflow(
        FakeProbe(
            [
                (reauthentication_required("alpha"), ready("beta")),
                ProbeError("verification broke"),
            ]
        ),
        FakeLogin({"alpha": 0}),
    )

    assert status == 1
    assert "error: verification failed: verification broke" in output
