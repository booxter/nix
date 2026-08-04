from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Protocol, Sequence

from sops_tools.errors import ToolError
from sops_tools.model import KeyPath
from sops_tools.process import ProcessRunner
from sops_tools.repository import RuntimeEnvironment, SecretRepository
from sops_tools.secrets import CommandSopsBackend

from .models import ExporterConfig, FleetHosts, IssueSummary
from .repository import host_facts


@dataclass(frozen=True)
class TokenRequest:
    user: str
    token_name: str
    role: str
    acl_path: str
    replace: bool
    comment: str


class TokenIssuer(Protocol):
    def issue(self, host: str, system: str, request: TokenRequest) -> str: ...


class TokenStore(Protocol):
    def set(self, host: str, key: KeyPath, value: str) -> None: ...


class ExporterConfigSource(Protocol):
    def exporter_config(self, host: str) -> ExporterConfig: ...

    def optional_exporter_config(self, host: str) -> ExporterConfig | None: ...


@dataclass(frozen=True)
class RemoteTokenIssuer:
    runner: ProcessRunner
    repo_root: Path

    def issue(self, host: str, system: str, request: TokenRequest) -> str:
        package = self._build(system)
        self.runner.run(["nix", "copy", "--to", f"ssh://{host}", str(package)])
        arguments = [
            str(package / "bin/issue-proxmox-exporter-token-remote"),
            "--user",
            request.user,
            "--token-name",
            request.token_name,
            "--role",
            request.role,
            "--path",
            request.acl_path,
            "--comment",
            request.comment,
        ]
        if request.replace:
            arguments.append("--replace")
        output = self.runner.run(["ssh", host, *arguments])
        value = output.strip()
        if not value:
            raise ToolError(f"remote token issuer on {host} returned no token")
        return value

    def _build(self, system: str) -> Path:
        flake = f"path:{self.repo_root}#packages.{system}.issue-proxmox-exporter-token"
        outputs = self.runner.run(
            ["nix", "build", "--no-link", "--print-out-paths", flake]
        ).splitlines()
        if len(outputs) != 1 or not outputs[0].startswith("/nix/store/"):
            raise ToolError(f"failed to build the Proxmox token helper for {system}")
        return Path(outputs[0])


@dataclass(frozen=True)
class SopsTokenStore:
    runtime: RuntimeEnvironment
    hosts: FleetHosts

    def set(self, host: str, key: KeyPath, value: str) -> None:
        domain = self.runtime.resolve_domain(host_facts(self.hosts, host).secret_domain)
        repository = SecretRepository(self.runtime.repo_root, domain)
        secret = repository.require_secret(host)
        runner = self._runner(domain.name, domain.identity_file)
        CommandSopsBackend(runner).set_value(secret, key, value)

    def _runner(self, domain: str, identity_file: Path | None) -> ProcessRunner:
        from sops_tools.process import SubprocessRunner

        environment = dict(self.runtime.values)
        if domain != "main" and identity_file is not None:
            environment["SOPS_AGE_KEY_FILE"] = str(identity_file)
        return SubprocessRunner(environment=environment)


@dataclass
class TokenService:
    hosts: FleetHosts
    evaluator: ExporterConfigSource
    issuer: TokenIssuer
    store: TokenStore

    def run(
        self,
        *,
        requested_hosts: Sequence[str] | None,
        issuer_host: str | None,
        request: TokenRequest,
        token_value: str | None,
    ) -> IssueSummary:
        selected = list(requested_hosts) if requested_hosts else self._enabled_exporter_hosts()
        if not selected:
            raise ToolError("no Proxmox exporter hosts selected")

        configs: dict[str, ExporterConfig] = {}
        for host in selected:
            host_facts(self.hosts, host)
            config = self.evaluator.exporter_config(host)
            if not config.enable:
                raise ToolError(f"host {host} does not enable the Proxmox exporter")
            if config.api_user != request.user:
                raise ToolError(
                    f"host {host} expects apiUser={config.api_user!r}, not {request.user!r}"
                )
            if config.api_token_name != request.token_name:
                raise ToolError(
                    f"host {host} expects apiTokenName={config.api_token_name!r}, "
                    f"not {request.token_name!r}"
                )
            configs[host] = config

        selected_issuer = issuer_host or selected[0]
        issuer_facts = host_facts(self.hosts, selected_issuer)
        value = token_value
        if value is None:
            value = self.issuer.issue(
                selected_issuer,
                issuer_facts.system,
                request,
            )

        for host in selected:
            self.store.set(
                host,
                KeyPath.parse(configs[host].api_token_value_secret),
                value,
            )

        return IssueSummary(
            issuer_host=selected_issuer,
            user=request.user,
            token_name=request.token_name,
            role=request.role,
            path=request.acl_path,
            updated_hosts=tuple(selected),
        )

    def _enabled_exporter_hosts(self) -> list[str]:
        selected: list[str] = []
        for host, facts in sorted(self.hosts.root.items()):
            if facts.is_work or not facts.system.endswith("-linux"):
                continue
            config = self.evaluator.optional_exporter_config(host)
            if config is not None and config.enable:
                selected.append(host)
        return selected
