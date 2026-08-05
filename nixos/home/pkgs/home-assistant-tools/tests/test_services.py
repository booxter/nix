from __future__ import annotations

import asyncio
from pathlib import Path

import pytest

from home_assistant_tools.auth import LocalAuthenticator
from home_assistant_tools.backup import BackupManager
from home_assistant_tools.bootstrap import Bootstrapper
from home_assistant_tools.errors import HomeAssistantError
from home_assistant_tools.models import AuthenticationConfig, BackupConfig, BootstrapConfig

from .fakes import (
    FakeTime,
    InMemoryBackupFactory,
    InMemoryBackupSession,
    InMemoryHomeAssistant,
    backup,
)


def authentication(tmp_path: Path) -> AuthenticationConfig:
    password_file = tmp_path / "password"
    password_file.write_text("secret\n", encoding="utf-8")
    return AuthenticationConfig("http://home", "client", "owner", password_file)


def bootstrap_config(tmp_path: Path) -> BootstrapConfig:
    return BootstrapConfig(authentication(tmp_path), "Owner Name", "en")


def test_fresh_bootstrap_creates_owner_and_completes_onboarding(tmp_path: Path) -> None:
    home_assistant = InMemoryHomeAssistant(status_failures=2)
    fake_time = FakeTime()
    authenticator = LocalAuthenticator(home_assistant, fake_time.sleep, fake_time.now)

    asyncio.run(
        Bootstrapper(home_assistant, authenticator, fake_time.sleep).run(bootstrap_config(tmp_path))
    )

    assert home_assistant.owner == ("Owner Name", "owner", "secret", "en")
    assert all(home_assistant.steps.values())
    assert home_assistant.integration == {
        "client_id": "client",
        "redirect_uri": "client",
    }


def test_interrupted_bootstrap_resumes_with_existing_owner(tmp_path: Path) -> None:
    home_assistant = InMemoryHomeAssistant(
        steps={
            "user": True,
            "core_config": True,
            "analytics": False,
            "integration": False,
        },
        owner=("Owner Name", "owner", "secret", "en"),
    )
    authenticator = LocalAuthenticator(home_assistant)

    asyncio.run(Bootstrapper(home_assistant, authenticator).run(bootstrap_config(tmp_path)))

    assert all(home_assistant.steps.values())


def test_completed_bootstrap_does_not_require_password_file(tmp_path: Path) -> None:
    home_assistant = InMemoryHomeAssistant(
        steps={
            "user": True,
            "core_config": True,
            "analytics": True,
            "integration": True,
        }
    )
    missing_authentication = AuthenticationConfig(
        "http://home",
        "client",
        "owner",
        tmp_path / "missing",
    )

    asyncio.run(
        Bootstrapper(home_assistant, LocalAuthenticator(home_assistant)).run(
            BootstrapConfig(missing_authentication, "Owner", "en")
        )
    )


def test_backup_login_retry_and_retention_preserve_newest_local_archives(
    tmp_path: Path,
) -> None:
    home_assistant = InMemoryHomeAssistant(
        steps={"user": True},
        owner=("Owner", "owner", "secret", "en"),
        login_failures=2,
    )
    session = InMemoryBackupSession(
        [backup(f"old-{day}", day) for day in range(2, 10)] + [backup("remote", 100, local=False)]
    )
    fake_time = FakeTime()
    authenticator = LocalAuthenticator(home_assistant, fake_time.sleep, fake_time.now)
    manager = BackupManager(
        authenticator,
        InMemoryBackupFactory(session),
        fake_time.sleep,
        fake_time.now,
    )

    asyncio.run(manager.run(BackupConfig(authentication(tmp_path))))

    local_ids = {item.backup_id for item in session.backups if "backup.local" in item.agents}
    assert local_ids == {"generated", "old-2", "old-3", "old-4", "old-5", "old-6", "old-7"}
    assert any(item.backup_id == "remote" for item in session.backups)


def test_stopped_backup_without_archive_preserves_existing_backups(tmp_path: Path) -> None:
    home_assistant = InMemoryHomeAssistant(
        steps={"user": True},
        owner=("Owner", "owner", "secret", "en"),
    )
    existing = [backup("existing", 2)]
    session = InMemoryBackupSession(list(existing), generation="failure")
    manager = BackupManager(
        LocalAuthenticator(home_assistant),
        InMemoryBackupFactory(session),
        FakeTime().sleep,
    )

    with pytest.raises(HomeAssistantError, match="stopped without a local archive"):
        asyncio.run(manager.run(BackupConfig(authentication(tmp_path))))

    assert session.backups == existing


def test_running_backup_honors_timeout(tmp_path: Path) -> None:
    home_assistant = InMemoryHomeAssistant(
        steps={"user": True},
        owner=("Owner", "owner", "secret", "en"),
    )
    session = InMemoryBackupSession([], generation="running")
    fake_time = FakeTime()
    manager = BackupManager(
        LocalAuthenticator(home_assistant, fake_time.sleep, fake_time.now),
        InMemoryBackupFactory(session),
        fake_time.sleep,
        fake_time.now,
    )

    with pytest.raises(TimeoutError, match="timed out"):
        asyncio.run(
            manager.run(
                BackupConfig(
                    authentication(tmp_path),
                    backup_timeout=3,
                    poll_interval=2,
                )
            )
        )
