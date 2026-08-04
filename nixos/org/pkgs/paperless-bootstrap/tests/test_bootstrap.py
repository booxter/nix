from __future__ import annotations

import os
import sys
from collections.abc import Iterator
from pathlib import Path

import pytest

from paperless_bootstrap.bootstrap import (
    Error,
    Repository,
    UserSpec,
    read_secret,
    reconcile,
    required_path,
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


def paperless_state() -> dict[str, object]:
    from allauth.account.models import EmailAddress
    from django.contrib.auth import get_user_model
    from django.contrib.auth.models import Group
    from rest_framework.authtoken.models import Token

    user_model = get_user_model()
    users = {
        user.username: {
            "email": user.email,
            "is_staff": user.is_staff,
            "is_superuser": user.is_superuser,
            "password": user.check_password("new-admin")
            if user.username == "ihar"
            else user.check_password("kasia-pass"),
        }
        for user in user_model.objects.filter(username__in=["ihar", "kasia"])
    }
    emails = list(
        EmailAddress.objects.filter(user__username="ihar")
        .order_by("email")
        .values("email", "verified", "primary")
    )
    return {
        "groups": sorted(Group.objects.values_list("name", flat=True)),
        "users": users,
        "emails": emails,
        "tokens": list(Token.objects.filter(user__username="ihar").values_list("key", flat=True)),
    }


def test_real_paperless_state_converges_and_rotates_credentials(
    paperless: None,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    from allauth.account.models import EmailAddress
    from django.contrib.auth import get_user_model

    admin_password = tmp_path / "admin-password"
    kasia_password = tmp_path / "kasia-password"
    token = tmp_path / "token"
    admin_password.write_text("old-admin\n")
    kasia_password.write_text("kasia-pass\n")
    token.write_text("a" * 40 + "\n")
    bootstrap_environment = {
        "PAPERLESS_IHAR_PASSWORD_FILE": str(admin_password),
        "PAPERLESS_KASIA_PASSWORD_FILE": str(kasia_password),
        "PAPERLESS_GPT_API_TOKEN_FILE": str(token),
    }

    reconcile(DjangoRepository(), bootstrap_environment)

    user = get_user_model().objects.get(username="ihar")
    user.email = "wrong@example.invalid"
    user.is_staff = False
    user.is_superuser = False
    user.save()
    address = EmailAddress.objects.get(user=user, email="ihar.hrachyshka@gmail.com")
    address.verified = False
    address.primary = False
    address.save()
    EmailAddress.objects.create(
        user=user,
        email="other@example.invalid",
        verified=True,
        primary=True,
    )
    admin_password.write_text("new-admin\n")
    token.write_text("b" * 40 + "\n")
    for name, value in bootstrap_environment.items():
        monkeypatch.setenv(name, value)

    main()
    main()

    assert paperless_state() == {
        "groups": ["paperless-admins", "paperless-users"],
        "users": {
            "ihar": {
                "email": "ihar.hrachyshka@gmail.com",
                "is_staff": True,
                "is_superuser": True,
                "password": True,
            },
            "kasia": {
                "email": "",
                "is_staff": False,
                "is_superuser": False,
                "password": True,
            },
        },
        "emails": [
            {
                "email": "ihar.hrachyshka@gmail.com",
                "verified": True,
                "primary": True,
            },
            {
                "email": "other@example.invalid",
                "verified": True,
                "primary": False,
            },
        ],
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
    kasia = tmp_path / "kasia"
    token = tmp_path / "token"
    admin.write_text("admin")
    kasia.write_text("kasia")
    token.write_text("short")

    with pytest.raises(Error, match="40-character"):
        reconcile(
            UntouchedRepository(),
            {
                "PAPERLESS_IHAR_PASSWORD_FILE": str(admin),
                "PAPERLESS_KASIA_PASSWORD_FILE": str(kasia),
                "PAPERLESS_GPT_API_TOKEN_FILE": str(token),
            },
        )


@pytest.mark.parametrize("contents", ["", "\n\r"])
def test_empty_secret_is_rejected(tmp_path: Path, contents: str) -> None:
    path = tmp_path / "empty"
    path.write_text(contents)

    with pytest.raises(Error, match="empty"):
        read_secret(path)


def test_missing_secret_file_is_reported_without_contents(tmp_path: Path) -> None:
    path = tmp_path / "missing"

    with pytest.raises(Error, match=str(path)):
        read_secret(path)


@pytest.mark.parametrize(
    ("environment", "message"),
    [({}, "missing"), ({"SECRET": "relative"}, "absolute")],
)
def test_secret_paths_are_required_and_absolute(
    environment: dict[str, str],
    message: str,
) -> None:
    with pytest.raises(Error, match=message):
        required_path(environment, "SECRET")
