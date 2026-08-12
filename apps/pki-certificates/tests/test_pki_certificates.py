from __future__ import annotations

import json
import os
from dataclasses import dataclass, field
from pathlib import Path

import pytest
from sops_tools.errors import ToolError
from sops_tools.repository import RuntimeEnvironment
from sops_tools.secrets import UpdateResult

from pki_certificates.cli import Application, run_internal, run_observability
from pki_certificates.issuer import RemoteCertificateIssuer, StepCaIssuer
from pki_certificates.models import (
    CertificateClientConfig,
    CertificateMaterial,
    CertificateRequest,
    FleetHosts,
    HostIdentity,
    InternalServiceConfig,
    ObservabilityEndpointConfig,
    RealmAuthorityConfig,
)
from pki_certificates.repository import NixConfigSource
from pki_certificates.secrets import SopsCertificateStore
from pki_certificates.services import ManagedCertificateService
from pki_certificates.unifi import UnifiCertificateService, validate_basename


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
    service: InternalServiceConfig = field(
        default_factory=lambda: InternalServiceConfig.model_validate(
            {
                "enable": True,
                "port": 443,
                "secretPrefix": "internal_https/web",
                "serverName": "web.example.invalid",
                "serverAliases": ["web", "web.local"],
                "sans": [],
            }
        )
    )
    client: CertificateClientConfig = field(
        default_factory=lambda: CertificateClientConfig.model_validate(
            {
                "enable": True,
                "category": "internal",
                "commonName": "client.host",
                "sans": ["client-alt"],
                "secretPrefix": "internal_https/clients/client",
            }
        )
    )
    endpoint: ObservabilityEndpointConfig = field(
        default_factory=lambda: ObservabilityEndpointConfig.model_validate(
            {
                "enable": True,
                "port": 9100,
                "sans": [],
                "secretPrefix": "prometheus/node",
            }
        )
    )

    def internal_service_names(self, host):
        return ["web"]

    def realm_authority(self, host):
        return realm_authority()

    def internal_service(self, host, name):
        return self.service

    def internal_client_names(self, host):
        return ["client"]

    def internal_client(self, host, name):
        return self.client

    def observability_endpoint_names(self, host):
        return ["node"]

    def observability_endpoint(self, host, name):
        return self.endpoint

    def observability_client_names(self, host):
        return ["scraper"]

    def observability_client(self, host, name):
        return self.client

    def host_identity(self, host):
        return HostIdentity(
            dns_name="host.example.invalid",
            networking_name="host",
            avahi_name="host",
        )


@dataclass
class RecordingIssuer:
    calls: list[tuple[str, str, tuple[str, ...]]] = field(default_factory=list)

    def issue(self, ca_host, common_name, sans):
        self.calls.append((ca_host, common_name, sans))
        return material()


@dataclass
class RecordingStore:
    calls: list[tuple[str, str, CertificateMaterial, bool]] = field(default_factory=list)

    def write(self, host, secret_prefix, certificate, *, client):
        self.calls.append((host, secret_prefix, certificate, client))


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
    assert [call[3] for call in store.calls] == [False, True, False, True]
    assert len(issuer.calls) == 4


def test_managed_service_rejects_disabled_configuration():
    source = StaticConfigSource()
    source.service = source.service.model_copy(update={"enable": False})
    service = ManagedCertificateService(source, RecordingIssuer(), RecordingStore())

    with pytest.raises(ToolError, match="is not enabled"):
        service.issue_internal_service("host", "web", "authority-node")


def test_nix_config_source_validates_and_combines_fleet_configuration():
    value = {
        "realm": "test-realm",
        "realm_authority": realm_authority().model_dump(by_alias=True),
        "identity": {
            "dns_name": "host.example.invalid",
            "networking_name": "host",
            "avahi_name": "host-avahi",
        },
        "internal_services": {
            "web": {
                "enable": True,
                "port": 443,
                "secretPrefix": "internal_https/web",
                "serverName": "web.example.invalid",
                "serverAliases": ["web"],
                "sans": ["web.example.invalid"],
            },
            "proxmox": {
                "enable": True,
                "port": 443,
                "secretPrefix": "proxmox/api",
                "serverName": "host",
            },
        },
        "proxmox_api": {
            "enable": True,
            "port": 8006,
            "secretPrefix": "proxmox/api",
            "serverName": "host",
            "serverAliases": ["host.example.invalid"],
        },
        "clients": {
            "internal": {
                "enable": True,
                "category": "internal",
                "commonName": "internal.host",
                "secretPrefix": "internal/client",
            },
            "external": {
                "enable": True,
                "category": "internal",
                "commonName": "external.host",
                "secretPrefix": "external/client",
            },
            "scraper": {
                "enable": True,
                "category": "observability",
                "commonName": "scraper.host",
                "secretPrefix": "prometheus/clients/scraper",
            },
        },
        "node_exporter": {
            "enable": True,
            "port": 9100,
            "secretPrefix": "prometheus/node_exporter",
            "sans": ["host", "host.local"],
        },
        "observability_endpoints": {
            "metrics": {
                "enable": True,
                "port": 9999,
                "secretPrefix": "prometheus/metrics",
                "sans": ["host"],
            }
        },
        "managed_certificates": [],
    }
    runner = AttributeRunner(value)
    source = NixConfigSource(runner, Path("/repo"), fleet_hosts(), Path("/query.nix"))

    assert source.internal_service_names("host") == ["web", "proxmox-api"]
    assert source.internal_service("host", "proxmox-api").port == 8006
    assert source.internal_client_names("host") == ["external", "internal"]
    assert source.internal_client("host", "external").common_name == "external.host"
    assert source.observability_endpoint_names("host") == ["node_exporter", "metrics"]
    assert source.observability_endpoint("host", "node_exporter").port == 9100
    assert source.observability_endpoint("host", "metrics").port == 9999
    assert source.observability_client_names("host") == ["scraper"]
    assert source.observability_client("host", "scraper").common_name == "scraper.host"
    assert source.host_identity("host").avahi_name == "host-avahi"
    assert source.certificate_config("host").identity.dns_name == "host.example.invalid"
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
        "--argstr",
        "configuration",
        "nixosConfigurations",
        "--argstr",
        "host",
        "host",
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

    store.write("host", "prometheus/client", material(), client=True)

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
