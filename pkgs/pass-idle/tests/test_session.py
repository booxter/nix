from __future__ import annotations

import stat
from collections.abc import Sequence
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from pathlib import Path
from threading import Event

import pytest
from pass_idle.session import FileSession, needs_session, run_with_session


@dataclass
class FakeCommands:
    resets: int = 0
    reset_status: int = 0
    pass_status: int = 0
    calls: list[list[str]] = field(default_factory=list)

    def reset(self) -> int:
        self.resets += 1
        return self.reset_status

    def run_pass(self, arguments: Sequence[str]) -> int:
        self.calls.append(list(arguments))
        return self.pass_status


def invoke(
    session: FileSession,
    commands: FakeCommands,
    start: float,
    finish: float | None = None,
) -> int:
    times = iter([start, finish if finish is not None else start])
    return run_with_session(
        ["show", "example"],
        commands=commands,
        session=session,
        clock=lambda: next(times),
        idle_seconds=900,
    )


def test_first_use_and_idle_timeout(tmp_path: Path) -> None:
    session = FileSession(tmp_path, "/home/test/.gnupg")
    commands = FakeCommands()

    assert invoke(session, commands, 1000) == 0
    assert commands.resets == 1
    assert invoke(session, commands, 1899, 2000) == 0
    assert commands.resets == 1
    assert session.last_used() == 2000

    # Measure from completion, including time spent in an interactive editor.
    assert invoke(session, commands, 2900) == 0
    assert commands.resets == 2
    assert len(commands.calls) == 3


def test_backwards_clock_expires_session(tmp_path: Path) -> None:
    session = FileSession(tmp_path, "home")
    commands = FakeCommands()
    invoke(session, commands, 1000)
    invoke(session, commands, 999)
    assert commands.resets == 2


def test_failed_pass_does_not_extend_session(tmp_path: Path) -> None:
    session = FileSession(tmp_path, "home")
    commands = FakeCommands()
    invoke(session, commands, 1000)
    commands.pass_status = 7

    assert invoke(session, commands, 1800) == 7
    assert session.last_used() == 1000
    invoke(session, commands, 1900)
    assert commands.resets == 2


def test_failed_reset_blocks_pass_and_is_retried(tmp_path: Path) -> None:
    session = FileSession(tmp_path, "home")
    commands = FakeCommands(reset_status=3)
    assert invoke(session, commands, 1000) == 3
    assert commands.calls == []
    assert session.last_used() is None

    commands.reset_status = 0
    assert invoke(session, commands, 1001) == 0
    assert commands.resets == 2
    assert len(commands.calls) == 1


@pytest.mark.parametrize(
    "content", ["", "broken", "null", "true", "{}", "[]", '"1"', "NaN", "1e999", "9" * 400]
)
def test_invalid_state_requires_reset(tmp_path: Path, content: str) -> None:
    session = FileSession(tmp_path, "home")
    with session.locked():
        session.timestamp.write_text(content)

    commands = FakeCommands()
    invoke(session, commands, 1000)
    assert commands.resets == 1
    assert session.last_used() == 1000


def test_state_is_private_and_shared_only_by_gnupg_home(tmp_path: Path) -> None:
    session = FileSession(tmp_path, "home")
    invoke(session, FakeCommands(), 1000)

    assert FileSession(tmp_path, "home").last_used() == 1000
    assert FileSession(tmp_path, "other").last_used() is None
    assert stat.S_IMODE(session.directory.stat().st_mode) == 0o700
    assert stat.S_IMODE(session.timestamp.stat().st_mode) == 0o600
    assert stat.S_IMODE(session.lock.stat().st_mode) == 0o600


def test_concurrent_use_waits_and_rechecks_updated_timestamp(tmp_path: Path) -> None:
    session = FileSession(tmp_path, "home")
    waiting = Event()
    commands = FakeCommands()

    def second_call() -> int:
        waiting.set()
        return invoke(FileSession(tmp_path, "home"), commands, 1001)

    with ThreadPoolExecutor() as executor:
        with session.locked():
            future = executor.submit(second_call)
            assert waiting.wait(timeout=5)
            with pytest.raises(TimeoutError):
                future.result(timeout=0.05)
            session.record(1000)

        assert future.result(timeout=5) == 0

    assert commands.resets == 0
    assert session.last_used() == 1001


@pytest.mark.parametrize(
    "command",
    [
        [],
        ["ls"],
        ["list"],
        ["show"],
        ["find", "name"],
        ["search", "name"],
        ["help"],
        ["--help"],
        ["version"],
        ["--version"],
    ],
)
def test_public_commands_do_not_need_authorization(command: list[str]) -> None:
    assert not needs_session(command)


@pytest.mark.parametrize(
    "command",
    [
        ["example"],
        ["show", "--clip", "example"],
        ["ls", "example"],
        ["list", "folder"],
        ["git", "diff"],
        ["edit", "example"],
        ["grep", "pattern"],
        ["init", "recipient"],
        ["otp", "example"],
    ],
)
def test_secret_and_extension_commands_need_authorization(command: list[str]) -> None:
    assert needs_session(command)
