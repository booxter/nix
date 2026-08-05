from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path

import pytest
from sops_tools.errors import CommandError, ToolError

from proxmox_exporter_token.models import ExporterConfig, FleetHosts
from proxmox_exporter_token.remote import PveumClient
from proxmox_exporter_token.repository import (
    NixEvaluator,
    configured_hosts_path,
    discover_repo_root,
    load_fleet_hosts,
)
from proxmox_exporter_token.service import (
    RemoteTokenIssuer,
    TokenRequest,
    TokenService,
)


@dataclass
class RecordingRunner:
    outputs: list[str] = field(default_factory=list)
    failures: set[int] = field(default_factory=set)
    calls: list[tuple[list[str], str | None, bool]] = field(default_factory=list)

    def run(self, argv, *, input_text=None, capture_output=True):
        index = len(self.calls)
        self.calls.append((list(argv), input_text, capture_output))
        if index in self.failures:
            raise CommandError(argv, 1, "not found")
        return self.outputs.pop(0) if self.outputs else ""

    def run_streaming(self, argv):
        raise AssertionError(f"unexpected streaming command: {argv}")


@dataclass
class StaticEvaluator:
    configs: dict[str, ExporterConfig]

    def exporter_config(self, host):
        return self.configs[host]

    def optional_exporter_config(self, host):
        return self.configs.get(host)


@dataclass
class RecordingIssuer:
    value: str = "issued-token"
    calls: list[tuple[str, TokenRequest]] = field(default_factory=list)

    def issue(self, host, request):
        self.calls.append((host, request))
        return self.value


@dataclass
class RecordingStore:
    calls: list[tuple[str, tuple[object, ...], str]] = field(default_factory=list)

    def set(self, host, key, value):
        self.calls.append((host, key.segments, value))


def fleet_hosts() -> FleetHosts:
    return FleetHosts.model_validate(
        {
            "prx1-lab": {
                "system": "x86_64-linux",
                "secretDomain": "main",
                "isWork": False,
            },
            "prx2-lab": {
                "system": "x86_64-linux",
                "secretDomain": "main",
                "isWork": False,
            },
            "work": {
                "system": "aarch64-darwin",
                "secretDomain": "work",
                "isWork": True,
            },
        }
    )


def exporter_config(*, enabled=True) -> ExporterConfig:
    return ExporterConfig.model_validate(
        {
            "enable": enabled,
            "apiUser": "prometheus@pve",
            "apiTokenName": "metrics",
            "apiTokenValueSecret": "proxmox/pve_exporter/token_value",
        }
    )


def token_request(*, replace=False) -> TokenRequest:
    return TokenRequest(
        user="prometheus@pve",
        token_name="metrics",
        role="PVEAuditor",
        acl_path="/",
        replace=replace,
        comment="metrics user",
    )


def test_pveum_client_uses_structured_json_and_argument_lists():
    runner = RecordingRunner(
        outputs=[
            '[{"userid":"prometheus@pve"}]',
            "",
            '{"data":{"value":"secret-token"}}',
        ]
    )

    value = PveumClient(runner, ("sudo", "-n")).issue(
        user="prometheus@pve",
        token_name="metrics",
        role="PVEAuditor",
        acl_path="/",
        replace=False,
        comment="metrics user",
    )

    assert value == "secret-token"
    assert runner.calls == [
        (
            ["sudo", "-n", "pveum", "user", "list", "--output-format", "json"],
            None,
            True,
        ),
        (
            [
                "sudo",
                "-n",
                "pveum",
                "aclmod",
                "/",
                "-user",
                "prometheus@pve",
                "-role",
                "PVEAuditor",
            ],
            None,
            True,
        ),
        (
            [
                "sudo",
                "-n",
                "pveum",
                "user",
                "token",
                "add",
                "prometheus@pve",
                "metrics",
                "--privsep",
                "0",
                "--output-format",
                "json",
            ],
            None,
            True,
        ),
    ]


def test_pveum_client_creates_user_and_tolerates_missing_replaced_token():
    runner = RecordingRunner(
        outputs=["[]", "", "", '{"value":"new-token"}'],
        failures={3},
    )
    client = PveumClient(runner, ())

    value = client.issue(
        user="prometheus@pve",
        token_name="metrics",
        role="PVEAuditor",
        acl_path="/",
        replace=True,
        comment="metrics user",
    )

    assert value == "new-token"
    commands = [call[0] for call in runner.calls]
    assert commands[1] == [
        "pveum",
        "user",
        "add",
        "prometheus@pve",
        "--comment",
        "metrics user",
    ]
    assert commands[3] == [
        "pveum",
        "user",
        "token",
        "remove",
        "prometheus@pve",
        "metrics",
    ]


@pytest.mark.parametrize(
    ("outputs", "message"),
    [
        (["not-json"], "invalid pveum user list"),
        (["[]", "", '{"data":{}}'], "invalid pveum token response"),
    ],
)
def test_pveum_client_rejects_invalid_json_responses(outputs, message):
    with pytest.raises(ToolError, match=message):
        PveumClient(RecordingRunner(outputs=outputs), ()).issue(
            user="prometheus@pve",
            token_name="metrics",
            role="PVEAuditor",
            acl_path="/",
            replace=False,
            comment="metrics user",
        )


def test_service_builds_for_issuer_system_and_updates_selected_secrets():
    request = token_request(replace=True)
    configs = {
        "prx1-lab": exporter_config(),
        "prx2-lab": exporter_config(),
    }
    issuer = RecordingIssuer()
    store = RecordingStore()
    service = TokenService(fleet_hosts(), StaticEvaluator(configs), issuer, store)

    summary = service.run(
        requested_hosts=["prx1-lab", "prx2-lab"],
        issuer_host="prx2-lab",
        request=request,
        token_value=None,
    )

    assert issuer.calls == [("prx2-lab", request)]
    assert store.calls == [
        (
            "prx1-lab",
            ("proxmox", "pve_exporter", "token_value"),
            "issued-token",
        ),
        (
            "prx2-lab",
            ("proxmox", "pve_exporter", "token_value"),
            "issued-token",
        ),
    ]
    assert summary.updated_hosts == ("prx1-lab", "prx2-lab")


def test_service_discovers_enabled_non_work_hosts_and_accepts_existing_token():
    issuer = RecordingIssuer()
    store = RecordingStore()
    service = TokenService(
        fleet_hosts(),
        StaticEvaluator(
            {
                "prx1-lab": exporter_config(),
                "prx2-lab": exporter_config(enabled=False),
            }
        ),
        issuer,
        store,
    )

    summary = service.run(
        requested_hosts=None,
        issuer_host=None,
        request=token_request(),
        token_value="existing-token",
    )

    assert summary.issuer_host == "prx1-lab"
    assert issuer.calls == []
    assert store.calls[0][2] == "existing-token"


def test_remote_issuer_copies_source_and_builds_on_target():
    source = "/nix/store/test-source"
    runner = RecordingRunner(outputs=[f'{{"path":"{source}"}}', "", "remote-token\n"])
    issuer = RemoteTokenIssuer(runner, Path("/repo"))

    request = token_request()
    value = issuer.issue("prx1-lab", request)

    assert value == "remote-token"
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
        "ssh-ng://prx1-lab",
        source,
    ]
    assert runner.calls[2][0] == [
        "ssh",
        "prx1-lab",
        "nix shell -L --show-trace 'path:/nix/store/test-source#issue-proxmox-exporter-token' "
        "--command issue-proxmox-exporter-token-remote",
    ]
    assert runner.calls[2][1] == (
        '{"user":"prometheus@pve","token_name":"metrics","role":"PVEAuditor",'
        '"acl_path":"/","replace":false,"comment":"metrics user"}'
    )


@pytest.mark.parametrize(
    ("outputs", "message"),
    [
        (["not-json"], "failed to archive"),
        (['{"path":"/nix/store/test"}', "", "\n"], "returned no token"),
    ],
)
def test_remote_issuer_rejects_invalid_results(outputs, message):
    issuer = RemoteTokenIssuer(RecordingRunner(outputs=outputs), Path("/repo"))

    with pytest.raises(ToolError, match=message):
        issuer.issue("prx1-lab", token_request())


def test_repository_boundaries_validate_inventory_and_nix_json(tmp_path: Path):
    (tmp_path / "flake.nix").write_text("{}")
    inventory = tmp_path / "hosts.json"
    inventory.write_text(json.dumps(fleet_hosts().model_dump(by_alias=True)))

    assert discover_repo_root(tmp_path / "nested", str(tmp_path)) == tmp_path
    assert load_fleet_hosts(inventory).root["prx1-lab"].secret_domain == "main"

    runner = RecordingRunner(outputs=[json.dumps(exporter_config().model_dump(by_alias=True))])
    config = NixEvaluator(runner, tmp_path).exporter_config("prx1-lab")
    assert config.enable
    assert runner.calls[0][0][-1].endswith(
        "#nixosConfigurations.prx1-lab.config.host.proxmox.prometheusExporter"
    )


def test_repository_boundaries_report_invalid_configuration(tmp_path: Path):
    with pytest.raises(ToolError, match="is not configured"):
        configured_hosts_path({})
    with pytest.raises(ToolError, match="could not find"):
        discover_repo_root(tmp_path, None)
    with pytest.raises(ToolError, match="does not point to a flake checkout"):
        discover_repo_root(tmp_path, str(tmp_path / "missing"))

    invalid = tmp_path / "hosts.json"
    invalid.write_text("not-json")
    with pytest.raises(ToolError, match="invalid PKI tool host inventory"):
        load_fleet_hosts(invalid)

    runner = RecordingRunner(outputs=["not-json"])
    evaluator = NixEvaluator(runner, tmp_path)
    with pytest.raises(ToolError, match="nix returned invalid JSON"):
        evaluator.exporter_config("prx1-lab")


def test_service_rejects_mismatched_config():
    config = exporter_config().model_copy(update={"api_user": "different@pve"})
    service = TokenService(
        fleet_hosts(),
        StaticEvaluator({"prx1-lab": config}),
        RecordingIssuer(),
        RecordingStore(),
    )

    with pytest.raises(ToolError, match="expects apiUser"):
        service.run(
            requested_hosts=["prx1-lab"],
            issuer_host=None,
            request=token_request(),
            token_value="existing-token",
        )
