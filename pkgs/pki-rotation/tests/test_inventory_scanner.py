from __future__ import annotations

import json
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from pathlib import Path

import yaml
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID
from pki_certificates.models import PkiInventory

from pki_rotation.inventory import (
    InventoryCertificateSpecSource,
    load_inventory,
)
from pki_rotation.models import (
    CertificateCategory,
    CertificateSpec,
    SecretLocation,
    SourceKind,
)
from pki_rotation.scanner import CertificateScanner, parse_certificate


def inventory_value(repo_root: Path) -> dict[str, object]:
    secret_fields = {
        "internal_https_server": ("server_crt_unencrypted", "server_key"),
        "internal_https_client": ("client_crt_unencrypted", "client_key"),
        "observability_endpoint_server": ("server_crt_unencrypted", "server_key"),
        "observability_client": ("client_crt_unencrypted", "client_key"),
    }
    certificates = [
        ("internal_https_server", "web", "internal/web"),
        ("internal_https_server", "proxmox-api", "internal/proxmox"),
        ("internal_https_client", "internal", "clients/client"),
        ("internal_https_client", "external", "clients/external"),
        ("observability_client", "loki", "prometheus/loki"),
        ("observability_endpoint_server", "api", "prometheus/api"),
        (
            "observability_endpoint_server",
            "node_exporter",
            "prometheus/node_exporter",
        ),
    ]
    return {
        "authority": {
            "hostName": "authority-node",
            "realm": "test-realm",
            "url": "https://ca.example.invalid:8443",
            "provisioner": "bootstrap@example.invalid",
            "rootCaCertificate": str(repo_root / "root-ca.crt"),
        },
        "hosts": {
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
        },
        "repoRoot": str(repo_root),
        "certificates": [
            {
                "host": "service-node",
                "realm": "test-realm",
                "category": category,
                "name": name,
                "commonName": f"{name}.example.invalid",
                "sans": [],
                "secretPrefix": prefix,
                "secretPath": "secrets/test-realm/service-node.yaml",
                "certificateField": secret_fields[category][0],
                "keyField": secret_fields[category][1],
                "port": None,
            }
            for category, name, prefix in certificates
        ],
    }


def test_inventory_uses_realms_and_all_managed_categories(tmp_path: Path) -> None:
    inventory = PkiInventory.model_validate_json(json.dumps(inventory_value(tmp_path)))
    specs = InventoryCertificateSpecSource(inventory).specs(tmp_path, Path("/intermediate.crt"))

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
    secret_paths = {spec.secret.path for spec in specs if spec.secret is not None}
    assert secret_paths == {tmp_path / "secrets" / "test-realm" / "service-node.yaml"}
    assert specs[0].host == "authority-node"


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


def test_scanner_treats_missing_secret_file_as_missing(tmp_path: Path) -> None:
    source = StaticSpecs(
        (
            CertificateSpec(
                "host",
                CertificateCategory.INTERNAL_HTTPS_SERVER,
                "web",
                SourceKind.REPOSITORY_SECRET,
                secret=SecretLocation(
                    "host",
                    tmp_path / "missing.yaml",
                    "internal/web",
                    "server_crt_unencrypted",
                ),
            ),
        )
    )

    inventory = CertificateScanner(source, FixedClock(datetime(2026, 1, 1, tzinfo=UTC))).scan(
        tmp_path,
        Path("/unused"),
        45,
    )

    (missing,) = inventory.root
    assert not missing.parse_success
    assert missing.rotation_due


def test_parse_certificate_rejects_non_pem_text() -> None:
    try:
        parse_certificate("not a certificate")
    except ValueError as error:
        assert "PEM" in str(error)
    else:
        raise AssertionError("invalid certificate was accepted")


def test_inventory_source_adds_runtime_intermediate_certificate(tmp_path: Path) -> None:
    manifest_path = tmp_path / "inventory.json"
    value = inventory_value(tmp_path)
    certificates = value["certificates"]
    assert isinstance(certificates, list)
    value["certificates"] = certificates[:1]
    manifest_path.write_text(json.dumps(value))

    source = InventoryCertificateSpecSource(load_inventory(manifest_path))
    specs = source.specs(tmp_path, Path("/intermediate.crt"))

    assert [
        (spec.name, spec.file_path) for spec in specs if spec.category is CertificateCategory.CA
    ] == [
        ("intermediate", Path("/intermediate.crt")),
        ("root", tmp_path / "root-ca.crt"),
    ]
    leaf = next(spec for spec in specs if spec.category is not CertificateCategory.CA)
    assert leaf.secret is not None
    assert leaf.secret.path == tmp_path / "secrets/test-realm/service-node.yaml"
