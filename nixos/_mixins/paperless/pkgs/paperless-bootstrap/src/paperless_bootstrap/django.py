from __future__ import annotations

import os
from importlib import import_module
from pathlib import Path
from typing import Any

from paperless_bootstrap.bootstrap import Error, Repository, UserSpec, load_spec, reconcile


class DjangoRepository(Repository):
    def __init__(self) -> None:
        self.user_model: Any = import_module("django.contrib.auth").get_user_model()
        self.group_model: Any = import_module("django.contrib.auth.models").Group
        self.email_model: Any = import_module("allauth.account.models").EmailAddress
        self.token_model: Any = import_module("rest_framework.authtoken.models").Token

    def ensure_group(self, name: str) -> None:
        self.group_model.objects.get_or_create(name=name)

    def reconcile_user(self, spec: UserSpec, password: str) -> None:
        desired: dict[str, object] = {
            "is_staff": spec.is_staff,
            "is_superuser": spec.is_superuser,
        }
        if spec.email:
            desired["email"] = spec.email
        user, _ = self.user_model.objects.get_or_create(
            username=spec.username,
            defaults=desired,
        )
        changed = False
        for field, value in desired.items():
            if getattr(user, field) != value:
                setattr(user, field, value)
                changed = True
        if not user.check_password(password):
            user.set_password(password)
            changed = True
        if changed:
            user.save()

    def reconcile_primary_email(self, username: str, email: str) -> None:
        user = self.user_model.objects.get(username=username)
        address, _ = self.email_model.objects.get_or_create(
            user=user,
            email=email,
            defaults={"verified": True, "primary": True},
        )
        self.email_model.objects.filter(user=user, primary=True).exclude(pk=address.pk).update(
            primary=False
        )
        changed = False
        for field, value in {"verified": True, "primary": True}.items():
            if getattr(address, field) != value:
                setattr(address, field, value)
                changed = True
        if changed:
            address.save()

    def reconcile_token(self, username: str, token: str) -> None:
        user = self.user_model.objects.get(username=username)
        existing = self.token_model.objects.filter(user=user).first()
        if existing is None:
            self.token_model.objects.create(user=user, key=token)
        elif existing.key != token:
            existing.delete()
            self.token_model.objects.create(user=user, key=token)


def main() -> None:
    try:
        config_path = os.environ["PAPERLESS_BOOTSTRAP_CONFIG"]
    except KeyError as error:
        raise Error("PAPERLESS_BOOTSTRAP_CONFIG is not set") from error
    reconcile(DjangoRepository(), load_spec(Path(config_path)))
