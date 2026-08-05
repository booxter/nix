from __future__ import annotations

import sys

import pytest

from hba_flash.process import Command, FlashError, SubprocessRunner


def test_subprocess_runner_observes_exit_status() -> None:
    runner = SubprocessRunner()
    runner.run(Command((sys.executable, "-c", "pass")))
    runner.run(
        Command(
            (sys.executable, "-c", "raise SystemExit(3)"),
            check=False,
            quiet=True,
        )
    )

    with pytest.raises(FlashError, match="failed with exit code 3"):
        runner.run(Command((sys.executable, "-c", "raise SystemExit(3)")))


def test_subprocess_runner_reports_missing_executable() -> None:
    with pytest.raises(FlashError, match="could not execute"):
        SubprocessRunner().run(Command(("hba-flash-command-does-not-exist",)))

    SubprocessRunner().run(Command(("hba-flash-command-does-not-exist",), check=False, quiet=True))
