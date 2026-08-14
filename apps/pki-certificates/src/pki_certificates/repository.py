from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass, field
from pathlib import Path

from pydantic import ValidationError
from sops_tools.errors import ToolError
from sops_tools.process import ProcessRunner

from .models import (
    CertificateCategory,
    CertificateConfig,
    FleetHost,
    FleetHosts,
    HostCertificateConfig,
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


def query_fleet_hosts(runner: ProcessRunner, repo_root: Path, query: Path) -> FleetHosts:
    output = runner.run(
        [
            "nix-instantiate",
            "--eval",
            "--strict",
            "--json",
            str(query),
            "--argstr",
            "repo",
            str(repo_root),
        ]
    )
    try:
        return FleetHosts.model_validate_json(output)
    except ValidationError as error:
        raise ToolError(f"invalid evaluated PKI certificate host inventory: {error}") from error


def fleet_host(hosts: FleetHosts, host: str) -> FleetHost:
    try:
        return hosts.root[host]
    except KeyError as error:
        raise ToolError(f"unknown host: {host}") from error


@dataclass
class NixConfigSource:
    runner: ProcessRunner
    repo_root: Path
    hosts: FleetHosts
    query: Path
    _cache: dict[str, HostCertificateConfig] = field(default_factory=dict)

    def realm_authority(self, host: str) -> RealmAuthorityConfig:
        authority = self._config(host).realm_authority
        if authority is None:
            raise ToolError(f"host {host} belongs to a realm without a PKI authority")
        return authority

    def certificate_config(self, host: str) -> HostCertificateConfig:
        return self._config(host)

    def certificate_names(self, host: str, category: CertificateCategory) -> list[str]:
        return sorted(
            certificate.name
            for certificate in self._config(host).certificates
            if certificate.category == category
        )

    def certificate(self, host: str, category: CertificateCategory, name: str) -> CertificateConfig:
        for certificate in self._config(host).certificates:
            if certificate.category == category and certificate.name == name:
                return certificate
        raise ToolError(f"unknown {category} certificate {name} on host {host}")

    def _config(self, host: str) -> HostCertificateConfig:
        if host in self._cache:
            return self._cache[host]
        host_entry = fleet_host(self.hosts, host)
        output = self.runner.run(
            [
                "nix-instantiate",
                "--eval",
                "--strict",
                "--json",
                str(self.query),
                "--argstr",
                "repo",
                str(self.repo_root),
                "--argstr",
                "configuration",
                host_entry.configuration,
                "--argstr",
                "host",
                host,
            ]
        )
        try:
            config = HostCertificateConfig.model_validate_json(output)
        except ValidationError as error:
            raise ToolError(f"invalid certificate configuration for {host}: {error}") from error
        self._cache[host] = config
        return config
