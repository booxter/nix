from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Protocol

from sops_tools.model import KeyPath
from sops_tools.process import SubprocessRunner
from sops_tools.repository import Realm, RuntimeEnvironment, SecretRepository
from sops_tools.secrets import CommandSopsBackend, SecretService, UpdateResult

from .models import CertificateMaterial, FleetHosts
from .repository import fleet_host


class CertificateStore(Protocol):
    def write(
        self,
        host: str,
        secret_prefix: str,
        material: CertificateMaterial,
        *,
        certificate_field: str,
        key_field: str,
    ) -> None: ...


class SecretWriter(Protocol):
    def update(self, host: str, *, force: bool = False) -> UpdateResult: ...

    def set_text(self, host: str, key_path: KeyPath, value: str) -> Path: ...


class SecretWriterFactory(Protocol):
    def create(self, runtime: RuntimeEnvironment, realm: Realm) -> SecretWriter: ...


@dataclass(frozen=True)
class CommandSecretWriterFactory:
    def create(self, runtime: RuntimeEnvironment, realm: Realm) -> SecretWriter:
        environment = runtime.command_environment(realm)
        return SecretService(
            SecretRepository(runtime.repo_root, realm),
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
        certificate_field: str,
        key_field: str,
    ) -> None:
        host_entry = fleet_host(self.hosts, host)
        realm = self.runtime.resolve_realm(host_entry.realm)
        service = self.factory.create(self.runtime, realm)
        service.update(host)
        prefix = KeyPath.parse(secret_prefix)
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
