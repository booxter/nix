from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Protocol

from sops_tools.model import KeyPath
from sops_tools.process import SubprocessRunner
from sops_tools.repository import RuntimeEnvironment, SecretDomain, SecretRepository
from sops_tools.secrets import CommandSopsBackend, SecretService, UpdateResult

from .models import CertificateMaterial, FleetHosts
from .repository import host_facts


class CertificateStore(Protocol):
    def write(
        self,
        host: str,
        secret_prefix: str,
        material: CertificateMaterial,
        *,
        client: bool,
    ) -> None: ...


class SecretWriter(Protocol):
    def update(self, host: str, *, force: bool = False) -> UpdateResult: ...

    def set_text(self, host: str, key_path: KeyPath, value: str) -> Path: ...


class SecretWriterFactory(Protocol):
    def create(self, runtime: RuntimeEnvironment, domain: SecretDomain) -> SecretWriter: ...


@dataclass(frozen=True)
class CommandSecretWriterFactory:
    def create(self, runtime: RuntimeEnvironment, domain: SecretDomain) -> SecretWriter:
        environment = runtime.command_environment(domain)
        return SecretService(
            SecretRepository(runtime.repo_root, domain),
            CommandSopsBackend(
                SubprocessRunner(environment),
                runtime.repo_root / ".sops.yaml",
            ),
        )


@dataclass(frozen=True)
class SopsCertificateStore:
    runtime: RuntimeEnvironment
    hosts: FleetHosts
    factory: SecretWriterFactory = field(default_factory=CommandSecretWriterFactory)

    def write(
        self,
        host: str,
        secret_prefix: str,
        material: CertificateMaterial,
        *,
        client: bool,
    ) -> None:
        facts = host_facts(self.hosts, host)
        domain = self.runtime.resolve_domain(facts.secret_domain)
        service = self.factory.create(self.runtime, domain)
        service.update(host)
        prefix = KeyPath.parse(secret_prefix)
        certificate_field = "client_crt_unencrypted" if client else "server_crt_unencrypted"
        key_field = "client_key" if client else "server_key"
        service.set_text(
            host,
            prefix.child(certificate_field),
            material.certificate_pem.rstrip("\n"),
        )
        service.set_text(
            host,
            prefix.child(key_field),
            material.private_key_pem.rstrip("\n"),
        )
