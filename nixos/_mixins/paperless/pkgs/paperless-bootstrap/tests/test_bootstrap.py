from __future__ import annotations

import json
import os
import sys
from collections.abc import Iterator
from pathlib import Path

import pytest

from paperless_bootstrap.bootstrap import (
    Error,
    Repository,
    UserSpec,
    load_spec,
    read_secret,
    reconcile,
)
from paperless_bootstrap.django import DjangoRepository, main


@pytest.fixture(scope="module")
def paperless(tmp_path_factory: pytest.TempPathFactory) -> Iterator[None]:
    root = tmp_path_factory.mktemp("paperless")
    data = root / "data"
    media = root / "media"
    consume = root / "consume"
    home = root / "home"
    for directory in (data, media, consume, home):
        directory.mkdir()
    os.environ.update(
        {
            "DJANGO_SETTINGS_MODULE": "paperless.settings",
            "PAPERLESS_DATA_DIR": str(data),
            "PAPERLESS_MEDIA_ROOT": str(media),
            "PAPERLESS_CONSUMPTION_DIR": str(consume),
            "PAPERLESS_CACHE_BACKEND": "django.core.cache.backends.locmem.LocMemCache",
            "PAPERLESS_SECRET_KEY": "test-only-secret-key-that-is-long-enough-for-paperless",
            "PAPERLESS_REDIS": "redis://127.0.0.1:1",
            "PAPERLESS_TIME_ZONE": "UTC",
            "HOME": str(home),
        }
    )
    sys.path.insert(0, os.environ["PAPERLESS_SOURCE_DIR"])

    import django
    from django.core.management import call_command

    django.setup()
    call_command("migrate", interactive=False, verbosity=0)
    yield


def write_config(
    path: Path,
    admin_password: Path,
    user_password: Path,
    token: Path,
) -> None:
    path.write_text(
        json.dumps(
            {
                "groups": ["paperless-admins", "paperless-users"],
                "users": [
                    {
                        "username": "administrator",
                        "email": "administrator@example.test",
                        "passwordFile": str(admin_password),
                        "isStaff": True,
                        "isSuperuser": True,
                    },
                    {
                        "username": "reader",
                        "email": "",
                        "passwordFile": str(user_password),
                        "isStaff": False,
                        "isSuperuser": False,
                    },
                ],
                "token": {"owner": "administrator", "file": str(token)},
            }
        )
    )


def paperless_state() -> dict[str, object]:
    from allauth.account.models import EmailAddress
    from django.contrib.auth import get_user_model
    from django.contrib.auth.models import Group
    from rest_framework.authtoken.models import Token

    users = {
        user.username: {
            "email": user.email,
            "is_staff": user.is_staff,
            "is_superuser": user.is_superuser,
            "password": user.check_password("new-admin")
            if user.username == "administrator"
            else user.check_password("reader-pass"),
        }
        for user in get_user_model().objects.filter(username__in=["administrator", "reader"])
    }
    return {
        "groups": sorted(Group.objects.values_list("name", flat=True)),
        "users": users,
        "emails": list(
            EmailAddress.objects.filter(user__username="administrator")
            .order_by("email")
            .values("email", "verified", "primary")
        ),
        "tokens": list(
            Token.objects.filter(user__username="administrator").values_list("key", flat=True)
        ),
    }


def test_real_paperless_state_converges_and_rotates_credentials(
    paperless: None,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    from allauth.account.models import EmailAddress
    from django.contrib.auth import get_user_model

    admin_password = tmp_path / "admin-password"
    user_password = tmp_path / "user-password"
    token = tmp_path / "token"
    config = tmp_path / "config.json"
    admin_password.write_text("old-admin\n")
    user_password.write_text("reader-pass\n")
    token.write_text("a" * 40 + "\n")
    write_config(config, admin_password, user_password, token)

    reconcile(DjangoRepository(), load_spec(config))

    user = get_user_model().objects.get(username="administrator")
    user.email = "wrong@example.invalid"
    user.is_staff = False
    user.is_superuser = False
    user.save()
    address = EmailAddress.objects.get(user=user, email="administrator@example.test")
    address.verified = False
    address.primary = False
    address.save()
    sso_user = get_user_model().objects.get(username="reader")
    sso_user.email = "reader@example.test"
    sso_user.save()
    admin_password.write_text("new-admin\n")
    token.write_text("b" * 40 + "\n")
    monkeypatch.setenv("PAPERLESS_BOOTSTRAP_CONFIG", str(config))

    main()
    main()

    assert paperless_state() == {
        "groups": ["paperless-admins", "paperless-users"],
        "users": {
            "administrator": {
                "email": "administrator@example.test",
                "is_staff": True,
                "is_superuser": True,
                "password": True,
            },
            "reader": {
                "email": "reader@example.test",
                "is_staff": False,
                "is_superuser": False,
                "password": True,
            },
        },
        "emails": [{"email": "administrator@example.test", "verified": True, "primary": True}],
        "tokens": ["b" * 40],
    }


class UntouchedRepository(Repository):
    def ensure_group(self, name: str) -> None:
        raise AssertionError("invalid secrets must fail before reconciliation")

    def reconcile_user(self, spec: UserSpec, password: str) -> None:
        raise AssertionError("invalid secrets must fail before reconciliation")

    def reconcile_primary_email(self, username: str, email: str) -> None:
        raise AssertionError("invalid secrets must fail before reconciliation")

    def reconcile_token(self, username: str, token: str) -> None:
        raise AssertionError("invalid secrets must fail before reconciliation")


def test_invalid_token_fails_before_mutating_paperless(tmp_path: Path) -> None:
    admin = tmp_path / "admin"
    user = tmp_path / "user"
    token = tmp_path / "token"
    config = tmp_path / "config.json"
    admin.write_text("admin")
    user.write_text("user")
    token.write_text("short")
    write_config(config, admin, user, token)

    with pytest.raises(Error, match="40-character"):
        reconcile(UntouchedRepository(), load_spec(config))


@pytest.mark.parametrize("contents", ["", "\n\r"])
def test_empty_secret_is_rejected(tmp_path: Path, contents: str) -> None:
    path = tmp_path / "empty"
    path.write_text(contents)
    with pytest.raises(Error, match="empty"):
        read_secret(path)


def test_invalid_configuration_is_rejected(tmp_path: Path) -> None:
    config = tmp_path / "config.json"
    config.write_text('{"groups": [], "users": [], "token": {}}')
    with pytest.raises(Error, match="users"):
        load_spec(config)


def test_token_owner_must_be_a_declared_user(tmp_path: Path) -> None:
    password = tmp_path / "password"
    token = tmp_path / "token"
    config = tmp_path / "config.json"
    password.write_text("password")
    token.write_text("a" * 40)
    write_config(config, password, password, token)
    document = json.loads(config.read_text())
    document["token"]["owner"] = "missing"
    config.write_text(json.dumps(document))
    with pytest.raises(Error, match="token owner"):
        load_spec(config)
