from __future__ import annotations

from dataclasses import dataclass

from pydantic import SecretStr
from vikunja_provision.models import Credentials, ProvisionError, SopsTarget
from vikunja_provision.storage import SecretStore


@dataclass(frozen=True)
class TokenDistribution:
    seats: dict[str, SopsTarget]
    store: SecretStore

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
                    f"Not updated: {remaining}. Retry without --rotate-token."
                ) from error

    @staticmethod
    def _authorization(credentials: Credentials) -> SecretStr:
        return SecretStr("Bearer " + credentials.token.get_secret_value())
