from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

import pytest
from pass_idle.session import FileSession


@dataclass
class Harness:
    directory: Path
    env: dict[str, str]

    def run(self, *arguments: str, timeout: str = "900") -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                sys.executable,
                "-m",
                "coverage",
                "run",
                "--parallel-mode",
                "--source=pass_idle",
                "-m",
                "pass_idle.cli",
                "--pass-program",
                str(self.directory / "pass"),
                "--gpgconf",
                str(self.directory / "gpgconf"),
                "--idle-seconds",
                timeout,
                "--",
                *arguments,
            ],
            env=self.env,
            input="example input\n",
            capture_output=True,
            text=True,
            check=False,
        )

    def resets(self) -> list[str]:
        log = self.directory / "reset.log"
        return [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []


@pytest.fixture
def harness(tmp_path: Path) -> Harness:
    for program in ("pass", "gpgconf"):
        destination = tmp_path / program
        shutil.copyfile(Path(__file__).parent / "fixtures" / program, destination)
        destination.chmod(0o700)

    return Harness(
        tmp_path,
        dict(
            os.environ,
            XDG_STATE_HOME=str(tmp_path / "state"),
            TEST_GNUPG_HOME=str(tmp_path / "gnupg"),
            TEST_RESET_LOG=str(tmp_path / "reset.log"),
        ),
    )


def test_streams_arguments_and_successful_session(harness: Harness) -> None:
    result = harness.run("show", "entry with spaces", "--clip")
    assert result.returncode == 0
    assert json.loads(result.stdout) == {
        "arguments": ["show", "entry with spaces", "--clip"],
        "input": "example input\n",
    }
    assert result.stderr == "pass stderr\n"
    assert harness.resets() == ["scdaemon", "gpg-agent"]

    assert harness.run("another entry").returncode == 0
    assert harness.resets() == ["scdaemon", "gpg-agent"]


@pytest.mark.parametrize("command", [(), ("--help",), ("find", "name"), ("ls",)])
def test_public_commands_do_not_touch_state(harness: Harness, command: tuple[str, ...]) -> None:
    # Even a broken gpgconf must not interfere with listing or help.
    (harness.directory / "gpgconf").unlink()
    assert harness.run(*command).returncode == 0
    assert harness.resets() == []
    assert not (harness.directory / "state").exists()


@pytest.mark.parametrize("command", [("ls", "example"), ("list", "example"), ("git", "diff")])
def test_commands_that_can_decrypt_reset_authorization(
    harness: Harness, command: tuple[str, ...]
) -> None:
    assert harness.run(*command).returncode == 0
    assert harness.resets() == ["scdaemon", "gpg-agent"]


@pytest.mark.parametrize("daemon", ["scdaemon", "gpg-agent"])
def test_either_reset_failure_blocks_pass(harness: Harness, daemon: str) -> None:
    harness.env["TEST_FAIL_DAEMON"] = daemon
    result = harness.run("example")
    assert result.returncode == 4
    assert result.stdout == ""
    assert f"could not stop {daemon}; pass was not run" in result.stderr
    assert not list((harness.directory / "state").rglob("*.json"))


def test_pass_failure_preserves_status_without_refreshing_state(harness: Harness) -> None:
    harness.env["TEST_PASS_STATUS"] = "7"
    result = harness.run("example")
    assert result.returncode == 7
    assert "pass stderr" in result.stderr
    assert not list((harness.directory / "state").rglob("*.json"))


def test_signal_status(harness: Harness) -> None:
    harness.env["TEST_SIGNAL"] = "1"
    assert harness.run("example").returncode == 143


def test_home_lookup_failure_blocks_pass(harness: Harness) -> None:
    harness.env["TEST_HOME_STATUS"] = "5"
    result = harness.run("example")
    assert result.returncode == 1
    assert result.stdout == ""
    assert "pass-idle:" in result.stderr
    assert harness.resets() == []


def test_state_error_blocks_pass(harness: Harness) -> None:
    (harness.directory / "state").touch()
    result = harness.run("example")
    assert result.returncode == 1
    assert result.stdout == ""
    assert harness.resets() == []


def test_public_command_does_not_refresh_existing_session(harness: Harness) -> None:
    session = FileSession(Path(harness.env["XDG_STATE_HOME"]), harness.env["TEST_GNUPG_HOME"])
    with session.locked():
        session.record(1000)
    assert harness.run("ls").returncode == 0
    assert session.last_used() == 1000
    assert harness.resets() == []


@pytest.mark.parametrize("timeout", ["0", "-1", "invalid"])
def test_invalid_timeout(harness: Harness, timeout: str) -> None:
    result = harness.run("example", timeout=timeout)
    assert result.returncode == 2
    assert result.stdout == ""
    assert harness.resets() == []
