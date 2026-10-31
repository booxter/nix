import os
import sys
import time
from pathlib import Path
from threading import Event, Thread, Timer

import pytest
from fleet_macos_vm.process import Cancelled, Commands, Result


def test_process_delivers_stdin_once_and_captures_output() -> None:
    commands = Commands(os.environ, Event())
    result = commands.run(
        [
            sys.executable,
            "-c",
            "import sys,time\ndata=sys.stdin.read()\ntime.sleep(.3)\n"
            "print(data)\nsys.stderr.write('err')",
        ],
        input_data=b"payload",
    )
    result.require_success("test command")
    assert result.stdout == "payload\n"
    assert result.stderr == "err"


def test_failed_command_does_not_print_secret_arguments() -> None:
    with pytest.raises(RuntimeError, match="operation failed \\(2\\): refused"):
        Result(2, "", "refused\n").require_success("operation")


def test_command_deadline_terminates_child() -> None:
    with pytest.raises(TimeoutError, match="timed out"):
        Commands(os.environ, Event()).run(
            [sys.executable, "-c", "import time; time.sleep(30)"],
            timeout=0.05,
        )


def test_cancellation_interrupts_child_and_cleanup_can_still_run() -> None:
    event = Event()
    commands = Commands(os.environ, event)
    timer = Timer(0.1, event.set)
    timer.start()
    try:
        with pytest.raises(Cancelled):
            commands.run([sys.executable, "-c", "import time; time.sleep(30)"])
    finally:
        timer.join()
    assert commands.run([sys.executable, "-c", "pass"], cancellable=False).code == 0
    with pytest.raises(Cancelled):
        commands.start([sys.executable, "-c", "pass"])


def test_foreground_child_can_be_waited_for() -> None:
    child = Commands(os.environ, Event()).start([sys.executable, "-c", "pass"])
    assert child.wait(timeout=5) == 0


def test_cancellation_also_terminates_descendants(tmp_path: Path) -> None:
    started = tmp_path / "started"
    escaped = tmp_path / "escaped"
    descendant = (
        f"from pathlib import Path\nimport time\nPath({str(started)!r}).touch()\n"
        f"time.sleep(1)\nPath({str(escaped)!r}).touch()"
    )
    parent = (
        "import subprocess,sys,time\n"
        f"subprocess.Popen([sys.executable, '-c', {descendant!r}])\n"
        "time.sleep(30)"
    )
    cancelled = Event()

    def cancel_after_child_started() -> None:
        deadline = time.monotonic() + 5
        while not started.exists() and time.monotonic() < deadline:
            time.sleep(0.01)
        cancelled.set()

    observer = Thread(target=cancel_after_child_started)
    observer.start()
    try:
        with pytest.raises(Cancelled):
            Commands(os.environ, cancelled).run([sys.executable, "-c", parent], timeout=10)
    finally:
        observer.join()
    assert started.exists()
    time.sleep(1)
    assert not escaped.exists()
