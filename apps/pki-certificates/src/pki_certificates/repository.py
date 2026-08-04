from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass, field
from pathlib import Path

from pydantic import ValidationError
from sops_tools.errors import ToolError
from sops_tools.process import ProcessRunner

from .models import (
    CertificateClientConfig,
    FleetHosts,
    HostCertificateConfig,
    HostFacts,
    HostIdentity,
    InternalServiceConfig,
    ObservabilityEndpointConfig,
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


def load_fleet_hosts(path: Path) -> FleetHosts:
    try:
        return FleetHosts.model_validate_json(path.read_bytes())
    except (OSError, ValidationError) as error:
        raise ToolError(f"invalid PKI certificate host inventory {path}: {error}") from error


def host_facts(hosts: FleetHosts, host: str) -> HostFacts:
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

    def internal_service_names(self, host: str) -> list[str]:
        config = self._config(host)
        names = sorted(
            name
            for name, service in config.internal_services.items()
            if service.enable
            and not (
                name == "proxmox"
                and config.proxmox_api is not None
                and service.secret_prefix == config.proxmox_api.secret_prefix
            )
        )
        if config.proxmox_api is not None:
            names.append("proxmox-api")
        return names

    def internal_service(self, host: str, name: str) -> InternalServiceConfig:
        config = self._config(host)
        if name == "proxmox-api":
            if config.proxmox_api is None:
                raise ToolError(f"internal HTTPS service {name} on host {host} is not enabled")
            return config.proxmox_api
        try:
            return config.internal_services[name]
        except KeyError as error:
            raise ToolError(f"unknown internal HTTPS service {name} on host {host}") from error

    def internal_client_names(self, host: str) -> list[str]:
        config = self._config(host)
        return sorted(
            {
                name
                for clients in (config.internal_clients, config.external_clients)
                for name, client in clients.items()
                if client.enable
            }
        )

    def internal_client(self, host: str, name: str) -> CertificateClientConfig:
        config = self._config(host)
        matches = [
            clients[name]
            for clients in (config.internal_clients, config.external_clients)
            if name in clients
        ]
        enabled = [client for client in matches if client.enable]
        if len(enabled) > 1:
            raise ToolError(f"internal HTTPS client {name} is enabled twice on {host}")
        if enabled:
            return enabled[0]
        if matches:
            return matches[0]
        raise ToolError(f"unknown internal HTTPS client {name} on host {host}")

    def observability_endpoint_names(self, host: str) -> list[str]:
        config = self._config(host)
        names = ["node_exporter"] if config.node_exporter is not None else []
        names.extend(
            sorted(
                name
                for name, endpoint in config.observability_endpoints.items()
                if name != "node_exporter" and endpoint.enable
            )
        )
        return names

    def observability_endpoint(self, host: str, name: str) -> ObservabilityEndpointConfig:
        config = self._config(host)
        if name == "node_exporter":
            if config.node_exporter is None:
                raise ToolError(f"host {host} does not have node_exporter mTLS enabled")
            return config.node_exporter
        try:
            return config.observability_endpoints[name]
        except KeyError as error:
            raise ToolError(f"unknown observability endpoint {name} on host {host}") from error

    def observability_client_names(self, host: str) -> list[str]:
        return sorted(
            name
            for name, client in self._config(host).observability_clients.items()
            if client.enable
        )

    def observability_client(self, host: str, name: str) -> CertificateClientConfig:
        try:
            return self._config(host).observability_clients[name]
        except KeyError as error:
            raise ToolError(f"unknown observability client {name} on host {host}") from error

    def host_identity(self, host: str) -> HostIdentity:
        return self._config(host).identity

    def _config(self, host: str) -> HostCertificateConfig:
        if host in self._cache:
            return self._cache[host]
        facts = host_facts(self.hosts, host)
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
                facts.configuration,
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
