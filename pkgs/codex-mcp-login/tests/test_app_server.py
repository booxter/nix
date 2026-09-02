from __future__ import annotations

import os
import sys
from pathlib import Path

import pytest
from codex_mcp_login.app_server import ProbeError, SubprocessStatusProbe
from codex_mcp_login.models import StartupStatus

FAKE_CODEX = Path(__file__).with_name("fake_app_server.py")


def probe(mode: str, *, timeout_seconds: float = 2.0) -> SubprocessStatusProbe:
    return SubprocessStatusProbe(
        command=(sys.executable, str(FAKE_CODEX)),
        timeout_seconds=timeout_seconds,
        shutdown_timeout_seconds=0.1,
        environment={**os.environ, "FAKE_CODEX_MODE": mode},
    )


def test_collects_only_requested_terminal_statuses_in_requested_order() -> None:
    statuses = probe("mixed").probe(["beta", "alpha", "alpha"])

    assert [status.name for status in statuses] == ["beta", "alpha"]
    assert statuses[0].requires_reauthentication
    assert statuses[1].status is StartupStatus.READY


def test_returns_cancelled_status() -> None:
    (status,) = probe("cancelled").probe(["alpha"])

    assert status.status is StartupStatus.CANCELLED
    assert not status.requires_reauthentication


@pytest.mark.parametrize(
    ("mode", "message"),
    [
        ("exit", "exited with code 7"),
        ("malformed", "invalid JSON-RPC"),
        ("thread-error", "could not start probe: could not start"),
        ("timeout", "timed out waiting"),
    ],
)
def test_reports_app_server_failures(mode: str, message: str) -> None:
    with pytest.raises(ProbeError, match=message):
        probe(mode, timeout_seconds=0.1).probe(["alpha"])


def test_reports_missing_codex_executable() -> None:
    with pytest.raises(ProbeError, match="could not execute"):
        SubprocessStatusProbe(command=("missing-codex-executable",)).probe(["alpha"])


def test_empty_server_list_needs_no_process() -> None:
    assert SubprocessStatusProbe(command=("missing-codex-executable",)).probe([]) == ()
