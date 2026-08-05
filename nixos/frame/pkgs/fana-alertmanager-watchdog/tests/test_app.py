from __future__ import annotations

import os
from pathlib import Path

import pytest

from fana_alertmanager_watchdog.app import (
    Arguments,
    MtlsReadinessProbe,
    ProbeResult,
    Runtime,
    StateStore,
    Status,
    TelegramNotifier,
    credential_path,
    format_status_message,
    main,
    parse_arguments,
    read_secret,
    run,
    runtime as build_runtime,
    should_notify,
    truncate,
)


class StaticProbe:
    def __init__(self, result: ProbeResult) -> None:
        self.result = result
        self.calls = 0

    def check(self) -> ProbeResult:
        self.calls += 1
        return self.result


class RecordingNotifier:
    def __init__(self) -> None:
        self.messages: list[str] = []

    def send(self, message: str) -> None:
        self.messages.append(message)


def make_runtime(
    tmp_path: Path, result: ProbeResult, repeat: int = 60
) -> tuple[Runtime, RecordingNotifier]:
    notifier = RecordingNotifier()
    return (
        Runtime(notifier, StaticProbe(result), repeat, StateStore(tmp_path), "https://fana/ready"),
        notifier,
    )


def test_first_failure_notifies_and_records_private_state(tmp_path: Path) -> None:
    runtime, notifier = make_runtime(tmp_path, ProbeResult("TLS <failed>", False))

    run(runtime, 100)

    assert runtime.state.status() is Status.DOWN
    assert runtime.state.error_file.read_text() == "TLS <failed>\n"
    assert runtime.state.notified_file.read_text() == "100\n"
    assert "TLS &lt;failed&gt;" in notifier.messages[0]
    assert os.stat(tmp_path).st_mode & 0o777 == 0o700


def test_repeated_failure_waits_until_repeat_window(tmp_path: Path) -> None:
    runtime, notifier = make_runtime(tmp_path, ProbeResult("still down", False))
    run(runtime, 100)

    run(runtime, 159)
    assert len(notifier.messages) == 1
    assert runtime.state.notified_file.read_text() == "100\n"

    run(runtime, 160)
    assert len(notifier.messages) == 2
    assert runtime.state.notified_file.read_text() == "160\n"


def test_recovery_notifies_once_and_clears_failure_state(tmp_path: Path) -> None:
    down_runtime, _ = make_runtime(tmp_path, ProbeResult("down", False))
    run(down_runtime, 100)
    up_runtime, notifier = make_runtime(tmp_path, ProbeResult("", True))

    run(up_runtime, 101)

    assert up_runtime.state.status() is Status.UP
    assert len(notifier.messages) == 1
    assert "Alert resolved" in notifier.messages[0]
    assert not up_runtime.state.error_file.exists()
    assert not up_runtime.state.notified_file.exists()

    run(up_runtime, 102)
    assert len(notifier.messages) == 1


def test_notify_decision_handles_state_and_invalid_timestamps(tmp_path: Path) -> None:
    state = StateStore(tmp_path)
    state.prepare()
    state.notified_file.write_text("invalid")

    assert state.last_notified() == 0
    assert should_notify(None, 10, 0, 60)
    assert not should_notify(Status.DOWN, 59, 0, 60)
    assert should_notify(Status.DOWN, 60, 0, 60)


def test_credentials_resolve_explicit_or_systemd_paths(tmp_path: Path) -> None:
    assert credential_path("telegram_chat_id", "/explicit/chat", {}) == Path("/explicit/chat")
    assert credential_path("telegram_chat_id", None, {"CREDENTIALS_DIRECTORY": str(tmp_path)}) == (
        tmp_path / "telegram-chat-id"
    )
    with pytest.raises(RuntimeError, match="CREDENTIALS_DIRECTORY"):
        credential_path("telegram_chat_id", None, {})


def test_secret_and_message_helpers_validate_and_escape(tmp_path: Path) -> None:
    secret = tmp_path / "secret"
    secret.write_text(" value \n")
    assert read_secret(secret) == "value"
    with pytest.raises(RuntimeError, match="empty or missing"):
        read_secret(tmp_path / "missing")

    assert truncate("  repeated\n whitespace  ") == "repeated whitespace"
    assert truncate("abcdef", 5) == "ab..."
    firing = format_status_message("https://fana?a=1&b=2", "<bad>", Status.DOWN)
    assert "a=1&amp;b=2" in firing
    assert "&lt;bad&gt;" in firing


def test_cli_uses_systemd_state_default() -> None:
    arguments = parse_arguments(
        ["--url", "https://fana/ready", "--ca-file", "/ca.pem"],
        {"STATE_DIRECTORY": "/state"},
    )

    assert arguments == Arguments(
        ca_file=Path("/ca.pem"),
        client_cert_file=None,
        client_key_file=None,
        repeat_after_seconds=21_600,
        state_dir=Path("/state"),
        telegram_bot_token_file=None,
        telegram_chat_id_file=None,
        timeout=10,
        url="https://fana/ready",
    )


def test_runtime_wires_explicit_credentials_into_native_backends(tmp_path: Path) -> None:
    arguments = Arguments(
        ca_file=Path("/ca.pem"),
        client_cert_file="/client.pem",
        client_key_file="/client-key.pem",
        repeat_after_seconds=30,
        state_dir=tmp_path,
        telegram_bot_token_file="/token",
        telegram_chat_id_file="/chat",
        timeout=2,
        url="https://fana/ready",
    )

    configured = build_runtime(arguments, {})

    assert configured.notifier == TelegramNotifier(Path("/token"), Path("/chat"))
    assert configured.probe == MtlsReadinessProbe(
        Path("/ca.pem"),
        Path("/client.pem"),
        Path("/client-key.pem"),
        2,
        "https://fana/ready",
    )
    assert configured.state == StateStore(tmp_path)


def test_main_reports_configuration_errors(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    monkeypatch.delenv("CREDENTIALS_DIRECTORY", raising=False)

    assert main(["--url", "https://fana/ready", "--ca-file", "/ca.pem"]) == 1
    assert "CREDENTIALS_DIRECTORY is not set" in capsys.readouterr().err
