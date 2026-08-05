from __future__ import annotations

import json
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path
import re

from pydantic import ValidationError
from sops_tools.errors import CommandError, ToolError
from sops_tools.process import ProcessRunner

from .models import ExporterConfig, FleetHosts, HostFacts


_SIMPLE_NIX_ATTRIBUTE = re.compile(r"[A-Za-z_][A-Za-z0-9_'-]*")


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


def load_fleet_hosts(path: Path) -> FleetHosts:
    try:
        return FleetHosts.model_validate_json(path.read_bytes())
    except (OSError, ValidationError) as error:
        raise ToolError(f"invalid PKI tool host inventory {path}: {error}") from error


def configured_hosts_path(environment: Mapping[str, str]) -> Path:
    value = environment.get("PKI_TOOLS_HOSTS_FILE")
    if not value:
        raise ToolError("PKI_TOOLS_HOSTS_FILE is not configured")
    return Path(value)


def nix_attribute(segment: str) -> str:
    return segment if _SIMPLE_NIX_ATTRIBUTE.fullmatch(segment) else json.dumps(segment)


@dataclass(frozen=True)
class NixEvaluator:
    runner: ProcessRunner
    repo_root: Path

    def exporter_config(self, host: str) -> ExporterConfig:
        value = self._json(
            "nixosConfigurations",
            host,
            "config",
            "host",
            "proxmox",
            "prometheusExporter",
        )
        try:
            return ExporterConfig.model_validate(value)
        except ValidationError as error:
            raise ToolError(f"invalid Proxmox exporter config for {host}: {error}") from error

    def optional_exporter_config(self, host: str) -> ExporterConfig | None:
        try:
            return self.exporter_config(host)
        except CommandError:
            return None

    def _json(self, *segments: str) -> object:
        attribute = ".".join(nix_attribute(segment) for segment in segments)
        flake = f"path:{self.repo_root}#{attribute}"
        raw = self.runner.run(["nix", "eval", "--json", flake])
        try:
            return json.loads(raw)
        except json.JSONDecodeError as error:
            raise ToolError(f"nix returned invalid JSON for {attribute}: {error}") from error


def host_facts(hosts: FleetHosts, host: str) -> HostFacts:
    try:
        return hosts.root[host]
    except KeyError as error:
        raise ToolError(f"unknown host: {host}") from error
