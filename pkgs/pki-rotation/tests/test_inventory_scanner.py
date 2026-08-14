from __future__ import annotations

import json
from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta
from pathlib import Path

import yaml
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID
from pki_certificates.models import FleetHosts, HostCertificateConfig

from pki_rotation.inventory import (
    CertificateInventoryBuilder,
    ManifestCertificateSpecSource,
    load_certificate_manifest,
)
from pki_rotation.models import (
    CertificateCategory,
    CertificateSpec,
    SecretLocation,
    SourceKind,
)
from pki_rotation.scanner import CertificateScanner, parse_certificate


def fleet_hosts() -> FleetHosts:
    return FleetHosts.model_validate(
        {
            "authority-node": {
                "system": "x86_64-linux",
                "configuration": "nixosConfigurations",
                "runtimeHost": "authority-runtime",
                "realm": "test-realm",
            },
            "service-node": {
                "system": "aarch64-darwin",
                "configuration": "darwinConfigurations",
                "runtimeHost": "service-runtime",
                "realm": "test-realm",
            },
        }
    )


def host_config() -> HostCertificateConfig:
    return HostCertificateConfig.model_validate(
        {
            "realm": "test-realm",
            "realm_authority": {
                "hostName": "authority-node",
                "realm": "test-realm",
                "url": "https://ca.example.invalid:8443",
                "provisioner": "bootstrap@example.invalid",
                "leafLifetimeDays": 180,
                "rootCaCertificate": "/repo/root-ca.crt",
            },
            "certificates": [
                {
                    "category": "internal_https_server",
                    "name": "web",
                    "commonName": "web.example.invalid",
                    "sans": ["web.example.invalid"],
                    "secretPrefix": "internal/web",
                },
                {
                    "category": "internal_https_server",
                    "name": "proxmox-api",
                    "commonName": "proxmox.example.invalid",
                    "sans": ["proxmox.example.invalid"],
                    "secretPrefix": "internal/proxmox",
                },
                {
                    "category": "internal_https_client",
                    "name": "internal",
                    "commonName": "client.example.invalid",
                    "sans": ["client.example.invalid"],
                    "secretPrefix": "clients/client",
                },
                {
                    "category": "internal_https_client",
                    "name": "external",
                    "commonName": "client.example.invalid",
                    "sans": ["client.example.invalid"],
                    "secretPrefix": "clients/external",
                },
                {
                    "category": "observability_client",
                    "name": "loki",
                    "commonName": "client.example.invalid",
                    "sans": [],
                    "secretPrefix": "prometheus/loki",
                },
                {
                    "category": "observability_endpoint_server",
                    "name": "api",
                    "commonName": "prometheus-api.host",
                    "sans": ["host"],
                    "secretPrefix": "prometheus/api",
                },
                {
                    "category": "observability_endpoint_server",
                    "name": "node_exporter",
                    "commonName": "prometheus-node_exporter.host",
                    "sans": ["host"],
                    "secretPrefix": "prometheus/node_exporter",
                },
            ],
        }
    )


@dataclass
class StaticConfigs:
    value: HostCertificateConfig
    requested: list[str] = field(default_factory=list)

    def certificate_config(self, host: str) -> HostCertificateConfig:
        self.requested.append(host)
        return self.value


def test_inventory_uses_realms_and_all_managed_categories(tmp_path: Path) -> None:
    secret = tmp_path / "secrets" / "test-realm" / "service-node.yaml"
    secret.parent.mkdir(parents=True)
    secret.write_text("{}")
    configs = StaticConfigs(host_config())

    specs = CertificateInventoryBuilder(
        tmp_path,
        fleet_hosts(),
        configs,
        Path("/intermediate.crt"),
    ).specs()

    leaves = {
        (spec.category, spec.name) for spec in specs if spec.category is not CertificateCategory.CA
    }
    assert leaves == {
        (CertificateCategory.INTERNAL_HTTPS_SERVER, "web"),
        (CertificateCategory.INTERNAL_HTTPS_SERVER, "proxmox-api"),
        (CertificateCategory.INTERNAL_HTTPS_CLIENT, "internal"),
        (CertificateCategory.INTERNAL_HTTPS_CLIENT, "external"),
        (CertificateCategory.OBSERVABILITY_ENDPOINT_SERVER, "api"),
        (CertificateCategory.OBSERVABILITY_ENDPOINT_SERVER, "node_exporter"),
        (CertificateCategory.OBSERVABILITY_CLIENT, "loki"),
    }
    assert configs.requested == ["authority-node", "service-node"]
    assert all(spec.secret is None or spec.secret.path == secret for spec in specs)
    assert specs[0].host == "authority-runtime"


def certificate_pem(not_before: datetime, not_after: datetime) -> str:
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "web.example.invalid")])
    certificate = (
        x509.CertificateBuilder()
        .subject_name(name)
        .issuer_name(name)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(not_before)
        .not_valid_after(not_after)
        .sign(key, hashes.SHA256())
    )
    return certificate.public_bytes(serialization.Encoding.PEM).decode()


@dataclass(frozen=True)
class FixedClock:
    value: datetime

    def now(self) -> datetime:
        return self.value


@dataclass(frozen=True)
class StaticSpecs:
    values: tuple[CertificateSpec, ...]

    def specs(self, repo_root: Path, intermediate_certificate: Path) -> tuple[CertificateSpec, ...]:
        return self.values


def test_scanner_parses_files_and_treats_encrypted_values_as_missing(tmp_path: Path) -> None:
    now = datetime(2026, 1, 1, tzinfo=UTC)
    certificate = tmp_path / "certificate.pem"
    certificate.write_text(certificate_pem(now - timedelta(days=1), now + timedelta(days=10)))
    secret = tmp_path / "host.yaml"
    secret.write_text(
        yaml.safe_dump(
            {"internal": {"web": {"server_crt_unencrypted": "ENC[AES256_GCM,data:encrypted]"}}}
        )
    )
    source = StaticSpecs(
        (
            CertificateSpec(
                "host",
                CertificateCategory.CA,
                "root",
                SourceKind.REPOSITORY_FILE,
                file_path=certificate,
            ),
            CertificateSpec(
                "host",
                CertificateCategory.INTERNAL_HTTPS_SERVER,
                "web",
                SourceKind.REPOSITORY_SECRET,
                secret=SecretLocation(
                    "host",
                    secret,
                    "internal/web",
                    "server_crt_unencrypted",
                ),
            ),
        )
    )

    inventory = CertificateScanner(source, FixedClock(now)).scan(
        tmp_path,
        Path("/unused"),
        45,
    )

    parsed, missing = inventory.root
    assert parsed.parse_success
    assert parsed.rotation_due
    assert parsed.common_name == "web.example.invalid"
    assert parsed.days_remaining == 10
    assert not missing.parse_success
    assert missing.rotation_due


def test_parse_certificate_rejects_non_pem_text() -> None:
    try:
        parse_certificate("not a certificate")
    except ValueError as error:
        assert "PEM" in str(error)
    else:
        raise AssertionError("invalid certificate was accepted")


def test_manifest_source_adds_runtime_intermediate_certificate(tmp_path: Path) -> None:
    root = tmp_path / "root.crt"
    secret = tmp_path / "host.yaml"
    manifest_path = tmp_path / "inventory.json"
    manifest_path.write_text(
        json.dumps(
            {
                "authority_host": "authority-node",
                "realm": "test-realm",
                "certificates": [
                    {
                        "host": "authority-node",
                        "category": "ca",
                        "name": "root",
                        "source_kind": "repo_file",
                        "file_path": str(root),
                        "secret": None,
                    },
                    {
                        "host": "host",
                        "category": "internal_https_server",
                        "name": "web",
                        "source_kind": "repo_secret",
                        "file_path": None,
                        "secret": {
                            "host": "host",
                            "path": str(secret),
                            "prefix": "internal/web",
                            "certificate_field": "server_crt_unencrypted",
                        },
                    },
                ],
            }
        )
    )

    source = ManifestCertificateSpecSource(load_certificate_manifest(manifest_path))
    specs = source.specs(Path("/unused"), Path("/intermediate.crt"))

    assert [
        (spec.name, spec.file_path) for spec in specs if spec.category is CertificateCategory.CA
    ] == [
        ("intermediate", Path("/intermediate.crt")),
        ("root", root),
    ]
    leaf = next(spec for spec in specs if spec.category is not CertificateCategory.CA)
    assert leaf.secret is not None
    assert leaf.secret.path == secret
