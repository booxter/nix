from __future__ import annotations

import json
import re
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import cast

from .errors import CommandError, ToolError
from .process import ProcessRunner

_REALM_PATTERN = re.compile(r"^[a-z][a-z0-9-]*$")


@dataclass(frozen=True)
class Realm:
    name: str
    identity_file: Path | None


@dataclass(frozen=True)
class RuntimeEnvironment:
    repo_root: Path
    home: Path
    config_home: Path
    system_name: str
    hostname: str
    values: Mapping[str, str]

    @classmethod
    def discover(
        cls,
        runner: ProcessRunner,
        *,
        values: Mapping[str, str],
        cwd: Path,
        system_name: str,
        hostname: str,
    ) -> RuntimeEnvironment:
        configured_root = values.get("SOPS_TOOLS_REPO_ROOT")
        try:
            output = runner.run(["git", "-C", str(cwd), "rev-parse", "--show-toplevel"])
            repo_root = Path(output.strip())
        except CommandError:
            if not configured_root:
                raise
            repo_root = Path(configured_root)
        home = Path(values.get("HOME", str(Path.home())))
        config_home = Path(values.get("XDG_CONFIG_HOME", str(home / ".config")))
        return cls(repo_root, home, config_home, system_name, hostname, dict(values))

    def resolve_realm(self, explicit: str | None, *, require_identity: bool = True) -> Realm:
        name = explicit or self._inventory_realm(self.machine_hostname)
        if not _REALM_PATTERN.fullmatch(name):
            raise ToolError(f"Invalid realm: {name}")

        identity: Path | None = None
        if name != "home" and not self.values.get("SOPS_AGE_KEY_FILE"):
            identity = self.realm_identity_file(name)
            if require_identity and not identity.is_file():
                raise ToolError(f"Age identity for realm '{name}' not found: {identity}")
        return Realm(name, identity)

    def realm_identity_file(self, realm: str) -> Path:
        if realm == "home":
            raise ToolError("The home realm uses the default SOPS identity.")
        if self.system_name == "Darwin":
            return self.home / "Library/Application Support/sops/age" / f"{realm}.txt"
        return self.config_home / "sops/age" / f"{realm}.txt"

    @property
    def machine_hostname(self) -> str:
        return self.values.get("SOPS_MACHINE_HOSTNAME", self.hostname)

    def registered_realm(self, host: str) -> str:
        inventory = self._realm_inventory()
        try:
            return inventory[host]
        except KeyError as error:
            raise ToolError(f"No realm is registered for host: {host}") from error

    def assert_realm_host(self, realm: Realm, host: str) -> None:
        registered = self.registered_realm(host)
        if registered != realm.name:
            raise ToolError(f"Host {host} belongs to realm '{registered}', not '{realm.name}'.")

    def command_environment(self, realm: Realm) -> dict[str, str]:
        environment = dict(self.values)
        if realm.identity_file is not None:
            environment["SOPS_AGE_KEY_FILE"] = str(realm.identity_file)
        return environment

    def _inventory_realm(self, machine: str) -> str:
        inventory = self._realm_inventory()
        try:
            return inventory[machine]
        except KeyError as error:
            raise ToolError(
                f"No realm is registered for machine: {machine}\n"
                "Pass --realm explicitly or add the machine to fleet inventory."
            ) from error

    def _realm_inventory(self) -> dict[str, str]:
        inventory_path = self.values.get("SOPS_REALMS_FILE")
        if not inventory_path or not Path(inventory_path).is_file():
            raise ToolError(
                "SOPS_REALMS_FILE is not set to a readable inventory map.\n"
                "Run this helper through 'nix run .#sops-…' or pass --realm explicitly."
            )
        try:
            value = json.loads(Path(inventory_path).read_text())
        except (OSError, json.JSONDecodeError) as error:
            raise ToolError(f"Invalid realm inventory: {inventory_path}") from error
        if not isinstance(value, dict) or not all(
            isinstance(key, str) and isinstance(realm, str) for key, realm in value.items()
        ):
            raise ToolError(f"Invalid realm inventory: {inventory_path}")
        return cast(dict[str, str], value)


@dataclass(frozen=True)
class SecretRepository:
    root: Path
    realm: Realm

    @property
    def directory(self) -> Path:
        return self.root / "secrets" / self.realm.name

    @property
    def template(self) -> Path:
        return self.directory / "_template.yaml"

    def host_template(self, host: str) -> Path:
        return self.directory / "_templates" / f"{host}.yaml"

    def secret(self, host: str) -> Path:
        return self.directory / f"{host}.yaml"

    def require_secret(self, host: str, *, role: str | None = None) -> Path:
        path = self.secret(host)
        if not path.is_file():
            prefix = f"{role} secret" if role else "Secret"
            raise ToolError(f"{prefix} not found: {path}")
        return path
