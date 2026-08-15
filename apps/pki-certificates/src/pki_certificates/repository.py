from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass, field
from pathlib import Path
from typing import Protocol

from pydantic import ValidationError
from sops_tools.errors import ToolError
from sops_tools.process import ProcessRunner

from .models import (
    CertificateCategory,
    CertificateConfig,
    FleetHost,
    FleetHosts,
    PkiInventory,
    RealmAuthorityConfig,
)


def discover_repo_root(cwd: Path, configured: str | None) -> Path:
    for candidate in (cwd.resolve(), *cwd.resolve().parents):
        if (candidate / "flake.nix").is_file():
            return candidate
    if configured:
        candidate = Path(configured).expanduser().resolve()
        if (candidate / "flake.nix").is_file():
            return candidate
        raise ToolError(f"PKI_TOOLS_REPO_ROOT does not point to a flake checkout: {candidate}")
    raise ToolError("could not find the repository root from the current directory")


def configured_file(environment: Mapping[str, str], variable: str) -> Path:
    value = environment.get(variable)
    if not value:
        raise ToolError(f"{variable} is not configured")
    return Path(value)


def fleet_host(hosts: FleetHosts, host: str) -> FleetHost:
    try:
        return hosts.root[host]
    except KeyError as error:
        raise ToolError(f"unknown host: {host}") from error


class InventorySource(Protocol):
    def inventory(self, repo_root: Path) -> PkiInventory: ...


@dataclass
class NixInventorySource:
    runner: ProcessRunner
    query: Path
    _cache: dict[Path, PkiInventory] = field(default_factory=dict)

    def inventory(self, repo_root: Path) -> PkiInventory:
        root = repo_root.resolve()
        if root in self._cache:
            return self._cache[root]
        output = self.runner.run(
            [
                "nix-instantiate",
                "--eval",
                "--strict",
                "--json",
                str(self.query),
                "--argstr",
                "repo",
                str(root),
            ]
        )
        try:
            inventory = PkiInventory.model_validate_json(output)
        except ValidationError as error:
            raise ToolError(f"invalid evaluated PKI certificate inventory: {error}") from error
        self._cache[root] = inventory
        return inventory


@dataclass(frozen=True)
class InventoryConfigSource:
    inventory: PkiInventory

    def realm_authority(self, host: str) -> RealmAuthorityConfig:
        host_entry = fleet_host(self.inventory.hosts, host)
        authority = self.inventory.authority
        if host_entry.realm != authority.realm:
            raise ToolError(f"host {host} belongs to a realm without a PKI authority")
        return authority

    def certificate_names(self, host: str, category: CertificateCategory) -> list[str]:
        fleet_host(self.inventory.hosts, host)
        return sorted(
            certificate.name
            for certificate in self.inventory.certificates
            if certificate.host == host and certificate.category == category
        )

    def certificate(self, host: str, category: CertificateCategory, name: str) -> CertificateConfig:
        fleet_host(self.inventory.hosts, host)
        for certificate in self.inventory.certificates:
            if (
                certificate.host == host
                and certificate.category == category
                and certificate.name == name
            ):
                return certificate
        raise ToolError(f"unknown {category} certificate {name} on host {host}")
