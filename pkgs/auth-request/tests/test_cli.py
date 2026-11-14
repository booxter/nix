import os
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path

import pytest
from auth_request.pass_gpg import SubprocessLauncher, close_indicator


@pytest.fixture
def programs(tmp_path: Path) -> Path:
    for name in ("gpg", "indicator", "bar", "fd-probe"):
        target = tmp_path / name
        shutil.copyfile(Path(__file__).parent / "fixtures" / "program", target)
        target.chmod(0o700)
    return tmp_path


def test_gpg_preserves_caller_descriptors_without_inheriting_indicator_pipe(programs: Path) -> None:
    launcher = SubprocessLauncher()
    lease = launcher.indicator(str(programs / "indicator"), "OpenPGP")
    assert lease.stdin is not None
    reader, writer = os.pipe()
    try:
        os.set_inheritable(writer, True)
        process = launcher.gpg(str(programs / "fd-probe"), [str(writer), str(lease.stdin.fileno())])
        assert process.wait(timeout=5) == 0
        assert os.read(reader, 6) == b"status"
    finally:
        os.close(reader)
        os.close(writer)
        close_indicator(lease)


def command(module: str, *args: str) -> list[str]:
    return [
        sys.executable,
        "-m",
        "coverage",
        "run",
        "--parallel-mode",
        "--source=auth_request",
        "-m",
        module,
        *args,
    ]


def test_pass_streams_and_exit_status(programs: Path) -> None:
    result = subprocess.run(
        command(
            "auth_request.pass_gpg",
            "--gpg-program",
            str(programs / "gpg"),
            "--indicator",
            str(programs / "indicator"),
            "--label",
            "pass",
            "--",
            "-d",
        ),
        input="secret input",
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.stdout == "secret input"
    assert result.stderr == "gpg error\n"
    assert result.returncode == 17


def test_pass_preserves_sigkill_status(programs: Path) -> None:
    result = subprocess.run(
        command(
            "auth_request.pass_gpg",
            "--gpg-program",
            str(programs / "gpg"),
            "--indicator",
            str(programs / "indicator"),
            "--label",
            "pass",
            "--",
            "-d",
            "--kill-self",
        ),
        capture_output=True,
        check=False,
    )
    assert result.returncode == -signal.SIGKILL
    assert result.stderr == b""


@pytest.mark.parametrize("cancelled", [False, True])
def test_cli_indicator_lifecycle(programs: Path, cancelled: bool) -> None:
    log = programs / "bar.log"
    env = dict(os.environ, BAR_LOG=str(log))
    process = subprocess.Popen(
        command(
            "auth_request.indicator",
            "--sketchybar",
            str(programs / "bar"),
            "--background",
            "yellow",
            "--foreground",
            "black",
            "--label",
            "SSH",
        ),
        stdin=subprocess.PIPE,
        env=env,
    )
    try:
        for _ in range(200):
            if log.exists() and log.read_text():
                break
            time.sleep(0.01)
        assert "label=SSH" in log.read_text()
        if cancelled:
            process.send_signal(signal.SIGTERM)
        else:
            assert process.stdin is not None
            process.stdin.close()
        assert process.wait(timeout=5) == 0
        assert "--remove auth_request_" in log.read_text()
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
