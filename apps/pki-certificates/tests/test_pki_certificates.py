from __future__ import annotations

import json
import os
from dataclasses import dataclass, field
from pathlib import Path

import pytest
from pki_certificates.cli import Application, run_internal, run_observability
from pki_certificates.issuer import RemoteCertificateIssuer, StepCaIssuer
from pki_certificates.models import (
    CertificateConfig,
    CertificateMaterial,
    CertificateRequest,
    FleetHosts,
    RealmAuthorityConfig,
)
from pki_certificates.repository import InventoryConfigSource, NixInventorySource
from pki_certificates.secrets import SopsCertificateStore
from pki_certificates.services import ManagedCertificateService
from pki_certificates.unifi import UnifiCertificateService, validate_basename
from sops_tools.errors import ToolError
from sops_tools.repository import RuntimeEnvironment
from sops_tools.secrets import UpdateResult


@dataclass
class RecordingRunner:
    outputs: list[str] = field(default_factory=list)
    calls: list[tuple[list[str], str | None, bool]] = field(default_factory=list)

    def run(self, argv, *, input_text=None, capture_output=True):
        self.calls.append((list(argv), input_text, capture_output))
        return self.outputs.pop(0) if self.outputs else ""

    def run_streaming(self, argv):
        raise AssertionError(f"unexpected streaming command: {argv}")


@dataclass
class StepRunner(RecordingRunner):
    def run(self, argv, *, input_text=None, capture_output=True):
        self.calls.append((list(argv), input_text, capture_output))
        Path(argv[4]).write_text(" certificate \n")
        Path(argv[5]).write_text(" private-key \n")
        return ""


@dataclass
class AttributeRunner:
    value: object
    calls: list[list[str]] = field(default_factory=list)

    def run(self, argv, *, input_text=None, capture_output=True):
        self.calls.append(list(argv))
        return json.dumps(self.value)

    def run_streaming(self, argv):
        raise AssertionError(f"unexpected streaming command: {argv}")


def fleet_hosts() -> FleetHosts:
    return FleetHosts.model_validate(
        {
            "host": {
                "system": "x86_64-linux",
                "configuration": "nixosConfigurations",
                "runtimeHost": "host-runtime",
                "realm": "test-realm",
            },
            "authority-node": {
                "system": "x86_64-linux",
                "configuration": "nixosConfigurations",
                "runtimeHost": "authority-runtime",
                "realm": "test-realm",
            },
        }
    )


def material() -> CertificateMaterial:
    return CertificateMaterial(
        certificate_pem="certificate\n",
        private_key_pem="private-key\n",
    )


def realm_authority() -> RealmAuthorityConfig:
    return RealmAuthorityConfig.model_validate(
        {
            "hostName": "authority-node",
            "realm": "test-realm",
            "url": "https://ca.example.invalid:8443",
            "provisioner": "bootstrap@example.invalid",
            "leafLifetimeDays": 180,
            "rootCaCertificate": "/repo/root-ca.crt",
        }
    )


@dataclass
class StaticConfigSource:
    certificates: list[CertificateConfig] = field(
        default_factory=lambda: [
            CertificateConfig.model_validate(value)
            for value in [
                {
                    "category": "internal_https_server",
                    "name": "web",
                    "commonName": "web.example.invalid",
                    "sans": ["web", "web.example.invalid", "web.local"],
                    "secretPrefix": "internal_https/web",
                    "port": 443,
                },
                {
                    "category": "internal_https_client",
                    "name": "client",
                    "commonName": "client.host",
                    "sans": ["client.host", "client-alt"],
                    "secretPrefix": "internal_https/clients/client",
                },
                {
                    "category": "observability_endpoint_server",
                    "name": "node",
                    "commonName": "prometheus-node.host.example.invalid",
                    "sans": ["host.example.invalid", "host", "host.local"],
                    "secretPrefix": "prometheus/node",
                    "port": 9100,
                },
                {
                    "category": "observability_client",
                    "name": "scraper",
                    "commonName": "client.host",
                    "sans": ["client-alt"],
                    "secretPrefix": "internal_https/clients/client",
                },
            ]
        ]
    )

    def realm_authority(self, host):
        return realm_authority()

    def certificate_names(self, host, category):
        return sorted(
            certificate.name
            for certificate in self.certificates
            if certificate.category == category
        )

    def certificate(self, host, category, name):
        return next(
            certificate
            for certificate in self.certificates
            if certificate.category == category and certificate.name == name
        )


@dataclass
class RecordingIssuer:
    calls: list[tuple[str, str, tuple[str, ...]]] = field(default_factory=list)

    def issue(self, ca_host, common_name, sans):
        self.calls.append((ca_host, common_name, sans))
        return material()


@dataclass
class RecordingStore:
    calls: list[tuple[str, str, CertificateMaterial, str, str]] = field(default_factory=list)

    def write(self, host, secret_prefix, certificate, *, certificate_field, key_field):
        self.calls.append((host, secret_prefix, certificate, certificate_field, key_field))


@dataclass(frozen=True)
class StaticAuthoritySource:
    def realm_authority(self, host: str) -> RealmAuthorityConfig:
        return realm_authority()


def managed_service():
    issuer = RecordingIssuer()
    store = RecordingStore()
    return ManagedCertificateService(StaticConfigSource(), issuer, store), issuer, store


def test_step_ca_issuer_uses_native_temporary_files_and_argument_list():
    runner = StepRunner()
    request = CertificateRequest(
        common_name="web.example.invalid",
        sans=("web", "web.example.invalid"),
        ca_url="https://ca.example.invalid:8443",
        provisioner="bootstrap@example.invalid",
    )

    result = StepCaIssuer(runner).issue(request)

    assert result == material()
    command = runner.calls[0][0]
    assert command[:4] == ["step", "ca", "certificate", "web.example.invalid"]
    assert command[6:10] == ["--san", "web", "--san", "web.example.invalid"]
    assert command[-2:] == ["--ca-url", "https://ca.example.invalid:8443"]


def test_remote_issuer_copies_source_and_builds_on_ca_target():
    source = "/nix/store/certificate-source"
    runner = RecordingRunner(
        outputs=[
            f'{{"path":"{source}"}}',
            "",
            material().model_dump_json(),
        ]
    )
    issuer = RemoteCertificateIssuer(
        runner,
        Path("/repo"),
        fleet_hosts(),
        StaticAuthoritySource(),
        False,
        Path("/unused"),
    )

    result = issuer.issue("authority-node", "web.example.invalid", ("web",))

    assert result == material()
    assert runner.calls[0][0] == [
        "nix",
        "flake",
        "archive",
        "--json",
        "path:/repo",
    ]
    assert runner.calls[1][0] == [
        "nix",
        "copy",
        "--to",
        "ssh-ng://authority-node",
        source,
    ]
    assert runner.calls[2][0] == [
        "ssh",
        "authority-node",
        "sudo -n -H -u step-ca nix shell -L --show-trace "
        "'path:/nix/store/certificate-source#pki-certificates' --command "
        "pki-issue-certificate-remote",
    ]
    assert json.loads(runner.calls[2][1])["common_name"] == "web.example.invalid"


def test_remote_issuer_local_mode_uses_installed_helper():
    runner = RecordingRunner(outputs=[material().model_dump_json()])
    issuer = RemoteCertificateIssuer(
        runner,
        Path("/repo"),
        fleet_hosts(),
        StaticAuthoritySource(),
        True,
        Path("/nix/store/helper/bin/pki-issue-certificate-remote"),
    )

    assert issuer.issue("authority-node", "client", ()) == material()
    assert runner.calls[0][0] == [
        "sudo",
        "-n",
        "-H",
        "-u",
        "step-ca",
        "/nix/store/helper/bin/pki-issue-certificate-remote",
    ]


def test_managed_service_issues_each_certificate_kind():
    service, issuer, store = managed_service()

    internal = service.issue_internal_service("host", "web", "authority-node")
    client = service.issue_internal_client("host", "client", "authority-node")
    endpoint = service.issue_observability_endpoint("host", "node", "authority-node")
    observer = service.issue_observability_client("host", "scraper", "authority-node")

    assert internal.sans == ("web", "web.example.invalid", "web.local")
    assert client.sans == ("client.host", "client-alt")
    assert endpoint.common_name == "prometheus-node.host.example.invalid"
    assert endpoint.sans == ("host.example.invalid", "host", "host.local")
    assert observer.sans == ("client-alt",)
    assert [call[3:] for call in store.calls] == [
        ("server_crt_unencrypted", "server_key"),
        ("client_crt_unencrypted", "client_key"),
        ("server_crt_unencrypted", "server_key"),
        ("client_crt_unencrypted", "client_key"),
    ]
    assert len(issuer.calls) == 4


def test_nix_inventory_source_evaluates_once_and_provides_certificates():
    value = {
        "authority": realm_authority().model_dump(by_alias=True),
        "hosts": fleet_hosts().model_dump(by_alias=True),
        "repoRoot": "/repo",
        "certificates": [
            {
                "host": "host",
                "realm": "test-realm",
                "category": "internal_https_server",
                "name": "web",
                "commonName": "web.example.invalid",
                "sans": ["web.example.invalid"],
                "secretPrefix": "internal_https/web",
                "secretPath": "secrets/test-realm/host.yaml",
                "certificateField": "server_crt_unencrypted",
                "keyField": "server_key",
                "port": 443,
            },
            {
                "host": "host",
                "realm": "test-realm",
                "category": "internal_https_server",
                "name": "proxmox-api",
                "commonName": "host",
                "sans": ["host", "host.example.invalid"],
                "secretPrefix": "proxmox/api",
                "secretPath": "secrets/test-realm/host.yaml",
                "certificateField": "server_crt_unencrypted",
                "keyField": "server_key",
                "port": 8006,
            },
            {
                "host": "host",
                "realm": "test-realm",
                "category": "internal_https_client",
                "name": "external",
                "commonName": "external.host",
                "sans": ["external.host"],
                "secretPrefix": "external/client",
                "secretPath": "secrets/test-realm/host.yaml",
                "certificateField": "client_crt_unencrypted",
                "keyField": "client_key",
            },
            {
                "host": "host",
                "realm": "test-realm",
                "category": "observability_endpoint_server",
                "name": "node_exporter",
                "commonName": "prometheus-node_exporter.host",
                "sans": ["host", "host.local"],
                "secretPrefix": "prometheus/node_exporter",
                "secretPath": "secrets/test-realm/host.yaml",
                "certificateField": "server_crt_unencrypted",
                "keyField": "server_key",
                "port": 9100,
            },
            {
                "host": "host",
                "realm": "test-realm",
                "category": "observability_endpoint_server",
                "name": "metrics",
                "commonName": "prometheus-metrics.host",
                "sans": ["host"],
                "secretPrefix": "prometheus/metrics",
                "secretPath": "secrets/test-realm/host.yaml",
                "certificateField": "server_crt_unencrypted",
                "keyField": "server_key",
                "port": 9999,
            },
            {
                "host": "host",
                "realm": "test-realm",
                "category": "observability_client",
                "name": "scraper",
                "commonName": "scraper.host",
                "sans": [],
                "secretPrefix": "prometheus/clients/scraper",
                "secretPath": "secrets/test-realm/host.yaml",
                "certificateField": "client_crt_unencrypted",
                "keyField": "client_key",
            },
        ],
    }
    runner = AttributeRunner(value)
    inventories = NixInventorySource(runner, Path("/query.nix"))
    inventory = inventories.inventory(Path("/repo"))
    source = InventoryConfigSource(inventory)

    assert source.certificate_names("host", "internal_https_server") == [
        "proxmox-api",
        "web",
    ]
    assert source.certificate("host", "internal_https_server", "proxmox-api").port == 8006
    assert source.certificate_names("host", "internal_https_client") == ["external"]
    assert (
        source.certificate("host", "internal_https_client", "external").common_name
        == "external.host"
    )
    assert source.certificate_names("host", "observability_endpoint_server") == [
        "metrics",
        "node_exporter",
    ]
    assert source.certificate_names("host", "observability_client") == ["scraper"]
    assert inventories.inventory(Path("/repo")) is inventory
    assert len(runner.calls) == 1
    assert runner.calls[0] == [
        "nix-instantiate",
        "--eval",
        "--strict",
        "--json",
        "/query.nix",
        "--argstr",
        "repo",
        "/repo",
    ]


@dataclass
class RecordingSecretWriter:
    calls: list[tuple[str, object, object]] = field(default_factory=list)

    def update(self, host, *, force=False):
        self.calls.append(("update", host, force))
        return UpdateResult(Path("/secret"), False, False)

    def set_text(self, host, key_path, value):
        self.calls.append((host, key_path.segments, value))
        return Path("/secret")


@dataclass
class RecordingSecretFactory:
    writer: RecordingSecretWriter
    realms: list[str] = field(default_factory=list)

    def create(self, runtime, realm):
        self.realms.append(realm.name)
        return self.writer


def test_sops_store_updates_template_and_structured_secret_paths(tmp_path: Path):
    identity = tmp_path / "sops/age/test-realm.txt"
    identity.parent.mkdir(parents=True)
    identity.write_text("fictional test identity")
    runtime = RuntimeEnvironment(
        repo_root=tmp_path,
        home=tmp_path,
        config_home=tmp_path,
        system_name="Linux",
        hostname="host",
        values={},
    )
    writer = RecordingSecretWriter()
    factory = RecordingSecretFactory(writer)
    store = SopsCertificateStore(runtime, fleet_hosts(), factory)

    store.write(
        "host",
        "prometheus/client",
        material(),
        certificate_field="client_crt_unencrypted",
        key_field="client_key",
    )

    assert factory.realms == ["test-realm"]
    assert writer.calls == [
        ("update", "host", False),
        (
            "host",
            ("prometheus", "client", "client_crt_unencrypted"),
            "certificate",
        ),
        ("host", ("prometheus", "client", "client_key"), "private-key"),
    ]


def test_unifi_service_writes_secure_import_files(tmp_path: Path):
    issuer = RecordingIssuer()
    service = UnifiCertificateService(issuer)

    result = service.issue(
        ca_host="authority-node",
        output_dir=tmp_path,
        common_name="unifi.example.invalid",
        additional_sans=["unifi", "console.example.invalid"],
        gateway_ip="192.0.2.1",
        basename="console",
        force=False,
    )

    assert result.sans == (
        "unifi.example.invalid",
        "unifi",
        "console.example.invalid",
        "192.0.2.1",
    )
    assert (tmp_path / "console.crt").read_text() == "certificate\n"
    assert (tmp_path / "console.key").read_text() == "private-key\n"
    assert os.stat(tmp_path / "console.key").st_mode & 0o777 == 0o600
    with pytest.raises(ToolError, match="refusing to overwrite"):
        service.issue(
            ca_host="authority-node",
            output_dir=tmp_path,
            common_name="unifi.example.invalid",
            additional_sans=[],
            gateway_ip=None,
            basename="console",
            force=False,
        )
    with pytest.raises(ToolError, match="invalid output basename"):
        validate_basename("../console")


def test_cli_routes_internal_and_observability_modes(capsys):
    managed, _, _ = managed_service()
    application = Application(
        managed,
        UnifiCertificateService(RecordingIssuer()),
    )

    assert run_internal(["--host", "host", "--service", "web"], application=application) == 0
    assert (
        run_observability(["--host", "host", "--client", "scraper"], application=application) == 0
    )

    lines = capsys.readouterr().out.splitlines()
    assert json.loads(lines[0])["kind"] == "internal-service"
    assert json.loads(lines[1])["kind"] == "observability-client"
