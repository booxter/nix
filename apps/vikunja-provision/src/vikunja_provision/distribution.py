from __future__ import annotations

from dataclasses import dataclass
from typing import Protocol

from pydantic import SecretStr
from sops_tools.cli import Application
from sops_tools.errors import ToolError
from sops_tools.model import KeyPath, has_path, value_at
from vikunja_provision.models import Credentials, ProvisionError, SopsTarget


class TokenStore(Protocol):
    def read(self, host: str, target: SopsTarget) -> SecretStr | None: ...

    def write(self, host: str, target: SopsTarget, value: SecretStr) -> None: ...


@dataclass(frozen=True)
class SopsTokenStore:
    application: Application

    def read(self, host: str, target: SopsTarget) -> SecretStr | None:
        try:
            service = self.application.secrets(target.realm)
            path = service.repository.require_secret(host)
            document = service.sops.decrypt_data(path)
            key = KeyPath.parse(target.key)
            if not has_path(document, key):
                return None

            value = value_at(document, key)
        except ToolError as error:
            raise ProvisionError(f"Could not read SOPS secret {host}:{target.key}") from error

        if not isinstance(value, str):
            raise ProvisionError(f"SOPS secret {host}:{target.key} must be a string")

        return SecretStr(value)

    def write(self, host: str, target: SopsTarget, value: SecretStr) -> None:
        try:
            self.application.secrets(target.realm).set_text(
                host, KeyPath.parse(target.key), value.get_secret_value()
            )
        except ToolError as error:
            raise ProvisionError(f"Could not update SOPS secret {host}:{target.key}") from error


@dataclass(frozen=True)
class TokenDistribution:
    seats: dict[str, SopsTarget]
    store: TokenStore

    def plan(self, credentials: Credentials | None) -> list[str]:
        desired = self._authorization(credentials) if credentials is not None else None
        changes = []
        # Inspect every destination before provisioning can issue or rotate a token.
        for host, target in sorted(self.seats.items()):
            current = self.store.read(host, target)
            if desired is None or current != desired:
                changes.append(f"update SOPS secret {host}:{target.key}")

        return changes

    def publish(self, credentials: Credentials) -> None:
        authorization = self._authorization(credentials)
        hosts = sorted(self.seats)
        for index, host in enumerate(hosts):
            target = self.seats[host]
            try:
                if self.store.read(host, target) != authorization:
                    self.store.write(host, target, authorization)
            except ProvisionError as error:
                completed = ", ".join(hosts[:index]) or "none"
                remaining = ", ".join(hosts[index:])
                raise ProvisionError(
                    f"{error}. SOPS distribution stopped. Completed: {completed}. "
                    f"Not updated: {remaining}. Retry apply without --rotate-token."
                ) from error

    @staticmethod
    def _authorization(credentials: Credentials) -> SecretStr:
        return SecretStr("Bearer " + credentials.token.get_secret_value())
