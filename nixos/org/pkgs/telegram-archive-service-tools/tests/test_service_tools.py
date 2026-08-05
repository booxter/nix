from __future__ import annotations

import io
import json
from dataclasses import dataclass
from pathlib import Path

import pytest

from telegram_archive_service_tools.cli import load_auth_config, run_auth, run_service
from telegram_archive_service_tools.credentials import read_chat_ids
from telegram_archive_service_tools.runtime import Error, Launch
from telegram_archive_service_tools.systemd import active_state


@dataclass
class CapturingExecutor:
    launched: Launch | None = None

    def execute(self, launch: Launch) -> None:
        self.launched = launch


@dataclass(frozen=True)
class StaticUnitState:
    active: bool

    def is_active(self, unit_name: str) -> bool:
        assert unit_name == "telegram-archive-scheduler.service"
        return self.active


def write_credentials(directory: Path) -> None:
    directory.mkdir()
    (directory / "api-id").write_text("12345\n")
    (directory / "api-hash").write_text("hash-value\r\n")
    (directory / "phone").write_text("+15551234567\n")
    (directory / "chat-ids").write_text("[-1001, 2002.0]")


def auth_config(tmp_path: Path, credentials: Path) -> dict[str, object]:
    return {
        "executable": str(tmp_path / "telegram-archive"),
        "scheduler_unit": "telegram-archive-scheduler.service",
        "user": "telegram-archive",
        "state_directory": str(tmp_path / "state"),
        "credentials": {
            "api_id": str(credentials / "api-id"),
            "api_hash": str(credentials / "api-hash"),
            "phone": str(credentials / "phone"),
            "chat_ids": str(credentials / "chat-ids"),
        },
        "environment": {
            "BACKUP_PATH": "/var/lib/telegram-archive/backups",
            "LOG_LEVEL": "INFO",
        },
    }


def write_auth_config(tmp_path: Path, credentials: Path) -> Path:
    path = tmp_path / "auth.json"
    path.write_text(json.dumps(auth_config(tmp_path, credentials)))
    return path


def test_scheduler_launches_with_validated_credentials(tmp_path: Path) -> None:
    credentials = tmp_path / "credentials"
    write_credentials(credentials)
    executor = CapturingExecutor()
    stderr = io.StringIO()

    status = run_service(
        [str(tmp_path / "telegram-archive"), "schedule"],
        {"CREDENTIALS_DIRECTORY": str(credentials), "INHERITED": "yes"},
        stderr,
        executor,
        telegram=True,
    )

    assert status == 0
    assert stderr.getvalue() == ""
    assert executor.launched == Launch(
        executable=tmp_path / "telegram-archive",
        arguments=(str(tmp_path / "telegram-archive"), "schedule"),
        environment={
            "CREDENTIALS_DIRECTORY": str(credentials),
            "INHERITED": "yes",
            "TELEGRAM_API_ID": "12345",
            "TELEGRAM_API_HASH": "hash-value",
            "TELEGRAM_PHONE": "+15551234567",
            "CHAT_IDS": "-1001,2002",
            "DISPLAY_CHAT_IDS": "-1001,2002",
        },
    )


def test_viewer_receives_only_display_chat_ids(tmp_path: Path) -> None:
    credentials = tmp_path / "credentials"
    write_credentials(credentials)
    executor = CapturingExecutor()

    status = run_service(
        [str(tmp_path / "viewer"), "--host", "127.0.0.1", "--port", "8091"],
        {"CREDENTIALS_DIRECTORY": str(credentials)},
        io.StringIO(),
        executor,
        telegram=False,
    )

    assert status == 0
    assert executor.launched is not None
    assert executor.launched.arguments == (
        str(tmp_path / "viewer"),
        "--host",
        "127.0.0.1",
        "--port",
        "8091",
    )
    assert executor.launched.environment["DISPLAY_CHAT_IDS"] == "-1001,2002"
    assert "TELEGRAM_API_HASH" not in executor.launched.environment
    assert "CHAT_IDS" not in executor.launched.environment


def test_service_requires_systemd_credentials(tmp_path: Path) -> None:
    executor = CapturingExecutor()
    stderr = io.StringIO()

    status = run_service(
        [str(tmp_path / "telegram-archive"), "schedule"],
        {},
        stderr,
        executor,
        telegram=True,
    )

    assert status == 1
    assert "systemd credentials are required" in stderr.getvalue()
    assert executor.launched is None


@pytest.mark.parametrize(
    "value",
    [[], [True], [1.5], ["123"], {"chat": 123}],
)
def test_chat_ids_reject_values_the_archive_cannot_use(tmp_path: Path, value: object) -> None:
    path = tmp_path / "chat-ids"
    path.write_text(json.dumps(value))

    with pytest.raises(Error, match="non-empty JSON array of integers"):
        read_chat_ids(path)


def test_chat_ids_report_missing_file(tmp_path: Path) -> None:
    with pytest.raises(Error, match="failed to read"):
        read_chat_ids(tmp_path / "missing")


def test_auth_blocks_while_scheduler_is_active(tmp_path: Path) -> None:
    credentials = tmp_path / "missing-credentials"
    config = write_auth_config(tmp_path, credentials)
    executor = CapturingExecutor()
    stderr = io.StringIO()

    status = run_auth(
        ["--config", str(config)],
        {},
        stderr,
        executor,
        StaticUnitState(active=True),
    )

    assert status == 1
    assert "is running; stop it before authenticating" in stderr.getvalue()
    assert executor.launched is None


def test_auth_prepares_interactive_service_identity(tmp_path: Path) -> None:
    credentials = tmp_path / "credentials"
    write_credentials(credentials)
    config = write_auth_config(tmp_path, credentials)
    executor = CapturingExecutor()
    stderr = io.StringIO()

    status = run_auth(
        ["--config", str(config)],
        {"TERM": "xterm-256color"},
        stderr,
        executor,
        StaticUnitState(active=False),
    )

    assert status == 0
    assert stderr.getvalue() == ""
    assert executor.launched is not None
    assert executor.launched.executable == tmp_path / "telegram-archive"
    assert executor.launched.arguments == (str(tmp_path / "telegram-archive"), "auth")
    assert executor.launched.user == "telegram-archive"
    assert executor.launched.working_directory == tmp_path / "state"
    assert executor.launched.umask == 0o077
    assert executor.launched.environment["TERM"] == "xterm-256color"
    assert executor.launched.environment["BACKUP_PATH"] == "/var/lib/telegram-archive/backups"
    assert executor.launched.environment["TELEGRAM_API_HASH"] == "hash-value"
    assert executor.launched.environment["DISPLAY_CHAT_IDS"] == "-1001,2002"


def test_empty_secret_stops_auth_before_launch(tmp_path: Path) -> None:
    credentials = tmp_path / "credentials"
    write_credentials(credentials)
    (credentials / "api-hash").write_text("\n")
    config = write_auth_config(tmp_path, credentials)
    executor = CapturingExecutor()
    stderr = io.StringIO()

    status = run_auth(
        ["--config", str(config)],
        {},
        stderr,
        executor,
        StaticUnitState(active=False),
    )

    assert status == 1
    assert "API hash is empty" in stderr.getvalue()
    assert executor.launched is None


def test_missing_telegram_secret_stops_auth_before_launch(tmp_path: Path) -> None:
    credentials = tmp_path / "credentials"
    write_credentials(credentials)
    (credentials / "api-id").unlink()
    config = write_auth_config(tmp_path, credentials)
    executor = CapturingExecutor()
    stderr = io.StringIO()

    status = run_auth(
        ["--config", str(config)],
        {},
        stderr,
        executor,
        StaticUnitState(active=False),
    )

    assert status == 1
    assert "failed to read Telegram Archive API ID" in stderr.getvalue()
    assert executor.launched is None


def test_auth_configuration_rejects_unknown_fields(tmp_path: Path) -> None:
    credentials = tmp_path / "credentials"
    data = auth_config(tmp_path, credentials)
    data["unused_feature"] = True
    path = tmp_path / "auth.json"
    path.write_text(json.dumps(data))

    with pytest.raises(Error, match="failed to load"):
        load_auth_config(path)


@pytest.mark.parametrize("value", [b"active", "active"])
def test_active_state_accepts_systemd_encodings(value: bytes | str) -> None:
    assert active_state(value)


def test_active_state_rejects_other_states() -> None:
    assert not active_state(b"inactive")
