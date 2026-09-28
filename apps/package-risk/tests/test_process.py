from __future__ import annotations

import sys

import pytest
from package_risk.process import RiskError, SubprocessRunner


def test_subprocess_runner_captures_stdout_and_stdin() -> None:
    runner = SubprocessRunner()
    result = runner.run((sys.executable, "-c", "print(input().upper())"), stdin="hello")
    assert result.stdout == "HELLO\n"
    assert result.returncode == 0


def test_subprocess_runner_accepts_selected_exit_code() -> None:
    result = SubprocessRunner().run(
        (sys.executable, "-c", "raise SystemExit(2)"), accepted_codes=(0, 2)
    )
    assert result.returncode == 2


def test_subprocess_runner_reports_failure() -> None:
    with pytest.raises(RiskError, match="failed with exit code 4"):
        SubprocessRunner().run((sys.executable, "-c", "raise SystemExit(4)"))


def test_subprocess_runner_reports_missing_program() -> None:
    with pytest.raises(RiskError, match="could not execute"):
        SubprocessRunner().run(("/definitely/missing/package-risk-test",))
