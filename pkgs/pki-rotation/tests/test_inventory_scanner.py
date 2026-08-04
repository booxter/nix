from __future__ import annotations

from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta
from pathlib import Path

import yaml
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID
from pki_certificates.models import FleetHosts, HostCertificateConfig

from pki_rotation.inventory import CertificateInventoryBuilder
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
            "pki": {
                "system": "x86_64-linux",
                "configuration": "nixosConfigurations",
                "runtimeHost": "pki-runtime",
                "secretDomain": "main",
                "caUrl": "https://pki.home.arpa:8443",
            },
            "host": {
                "system": "aarch64-darwin",
                "configuration": "darwinConfigurations",
                "runtimeHost": "host-runtime",
                "secretDomain": "work",
                "caUrl": None,
            },
        }
    )


def host_config() -> HostCertificateConfig:
    client = {
        "enable": True,
        "commonName": "client.home.arpa",
        "sans": [],
        "secretPrefix": "clients/client",
    }
    return HostCertificateConfig.model_validate(
        {
            "identity": {
                "dns_name": "host.home.arpa",
                "networking_name": "host",
                "avahi_name": "host",
            },
            "internal_services": {
                "web": {
                    "enable": True,
                    "port": 443,
                    "secretPrefix": "internal/web",
                    "serverName": "web.home.arpa",
                },
                "proxmox": {
                    "enable": True,
                    "port": 8006,
                    "secretPrefix": "internal/proxmox",
                    "serverName": "proxmox.home.arpa",
                },
            },
            "internal_clients": {"internal": client},
            "external_clients": {"external": client | {"secretPrefix": "clients/external"}},
            "proxmox_api": {
                "enable": True,
                "port": 8006,
                "secretPrefix": "internal/proxmox",
                "serverName": "proxmox.home.arpa",
            },
            "observability_endpoints": {
                "api": {
                    "enable": True,
                    "port": 9090,
                    "secretPrefix": "prometheus/api",
                }
            },
            "observability_clients": {"loki": client | {"secretPrefix": "prometheus/loki"}},
            "node_exporter": {
                "enable": True,
                "port": 9100,
                "secretPrefix": "prometheus/node_exporter",
            },
        }
    )


@dataclass
class StaticConfigs:
    value: HostCertificateConfig
    requested: list[str] = field(default_factory=list)

    def certificate_config(self, host: str) -> HostCertificateConfig:
        self.requested.append(host)
        return self.value


def test_inventory_uses_secret_domains_and_all_managed_categories(tmp_path: Path) -> None:
    secret = tmp_path / "secrets" / "work" / "host.yaml"
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
        (CertificateCategory.EXTERNAL_SERVICE_CLIENT, "external"),
        (CertificateCategory.OBSERVABILITY_ENDPOINT_SERVER, "api"),
        (CertificateCategory.OBSERVABILITY_ENDPOINT_SERVER, "node_exporter"),
        (CertificateCategory.OBSERVABILITY_CLIENT, "loki"),
    }
    assert configs.requested == ["host"]
    assert all(spec.secret is None or spec.secret.path == secret for spec in specs)
    assert specs[0].host == "pki-runtime"


def certificate_pem(not_before: datetime, not_after: datetime) -> str:
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "web.home.arpa")])
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
    assert parsed.common_name == "web.home.arpa"
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
