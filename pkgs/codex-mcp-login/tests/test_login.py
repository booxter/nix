from __future__ import annotations

import sys

import pytest
from codex_mcp_login.login import LoginError, SubprocessLoginRunner


def test_returns_login_exit_status() -> None:
    runner = SubprocessLoginRunner(
        command=(sys.executable, "-c", "import sys; raise SystemExit(int(sys.argv[-1]))")
    )

    assert runner.login("0") == 0
    assert runner.login("7") == 7


def test_reports_missing_codex_executable() -> None:
    with pytest.raises(LoginError, match="could not execute"):
        SubprocessLoginRunner(command=("missing-codex-executable",)).login("alpha")
