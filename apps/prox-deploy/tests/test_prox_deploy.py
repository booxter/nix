from __future__ import annotations

import io
from collections.abc import Sequence
from dataclasses import dataclass, field
from pathlib import Path

import pytest

from prox_deploy.adapters import (
    CommandResult,
    NixmoxerDeployer,
    PassPasswordStore,
    ProxDeployError,
    load_nixmoxer_callback,
)
from prox_deploy.cli import load_vm_types, main, run_cli
from prox_deploy.core import DeployRequest, ProxmoxCredentials


@dataclass
class FakePasswordStore:
    password: str
    references: list[str] = field(default_factory=list)

    def read(self, reference: str) -> str:
        self.references.append(reference)
        return self.password


@dataclass
class RecordingDeployer:
    deployments: list[tuple[DeployRequest, ProxmoxCredentials]] = field(default_factory=list)

    def deploy(self, request: DeployRequest, credentials: ProxmoxCredentials) -> None:
        self.deployments.append((request, credentials))


@dataclass
class StubRunner:
    result: CommandResult
    calls: list[list[str]] = field(default_factory=list)

    def run(self, arguments: Sequence[str]) -> CommandResult:
        self.calls.append(list(arguments))
        return self.result


class FailingPasswordStore:
    def read(self, reference: str) -> str:
        raise ProxDeployError(f"cannot read {reference}")


def test_cli_resolves_password_reference_and_deploys() -> None:
    passwords = FakePasswordStore("secret-pass")
    deployer = RecordingDeployer()

    status = run_cli(
        ["srvarr", "prx1-lab"],
        vm_types=["srvarr", "builder1"],
        password_store=passwords,
        deployer=deployer,
        stderr=io.StringIO(),
    )

    assert status == 0
    assert passwords.references == ["host/prx1-lab/root"]
    assert deployer.deployments == [
        (
            DeployRequest(vm_type="srvarr", proxmox_host="prx1-lab"),
            ProxmoxCredentials(host="prx1-lab", user="root", password="secret-pass"),
        )
    ]


def test_cli_reports_expected_setup_errors() -> None:
    stderr = io.StringIO()

    status = run_cli(
        ["srvarr", "prx1-lab"],
        vm_types=["srvarr"],
        password_store=FailingPasswordStore(),
        deployer=RecordingDeployer(),
        stderr=stderr,
    )

    assert status == 1
    assert stderr.getvalue() == "prox-deploy: cannot read host/prx1-lab/root\n"


def test_pass_adapter_uses_show_and_strips_line_endings() -> None:
    runner = StubRunner(CommandResult(0, "secret-pass\r\n", ""))
    passwords = PassPasswordStore(Path("/nix/store/pass/bin/pass"), runner)

    assert passwords.read("host/prx1-lab/root") == "secret-pass"
    assert runner.calls == [["/nix/store/pass/bin/pass", "show", "host/prx1-lab/root"]]


@pytest.mark.parametrize(
    ("result", "message"),
    [
        (CommandResult(7, "", "entry missing\n"), "entry missing"),
        (CommandResult(0, "\n", ""), "entry is empty"),
    ],
)
def test_pass_adapter_reports_expected_failures(result: CommandResult, message: str) -> None:
    passwords = PassPasswordStore(Path("pass"), StubRunner(result))

    with pytest.raises(ProxDeployError, match=message):
        passwords.read("host/prx1-lab/root")


def test_nixmoxer_adapter_sets_and_restores_environment() -> None:
    environment = {"PROXMOX_USER": "previous", "UNRELATED": "kept"}
    calls: list[tuple[bool, str, dict[str, str]]] = []

    def callback(flake: bool, machine: str) -> object:
        calls.append((flake, machine, dict(environment)))
        return None

    deployer = NixmoxerDeployer(lambda: callback, environment)
    deployer.deploy(
        DeployRequest("srvarr", "prx1-lab"),
        ProxmoxCredentials("prx1-lab", "root", "secret-pass"),
    )

    assert calls == [
        (
            True,
            "srvarr",
            {
                "PROXMOX_HOST": "prx1-lab:8006",
                "PROXMOX_USER": "root@pam",
                "PROXMOX_PASSWORD": "secret-pass",
                "PROXMOX_VERIFY_SSL": "0",
                "UNRELATED": "kept",
            },
        )
    ]
    assert environment == {"PROXMOX_USER": "previous", "UNRELATED": "kept"}


def test_pinned_nixmoxer_exposes_bootstrap_callback() -> None:
    assert callable(load_nixmoxer_callback())


def test_vm_types_are_loaded_with_json_and_validated() -> None:
    assert load_vm_types('["srvarr", "builder1"]') == ("srvarr", "builder1")

    with pytest.raises(ProxDeployError, match="JSON string array"):
        load_vm_types('{"srvarr": true}')


def test_packaged_main_loads_settings_and_injected_dependencies() -> None:
    passwords = FakePasswordStore("secret-pass")
    deployer = RecordingDeployer()

    status = main(
        ["srvarr", "prx1-lab"],
        environment={
            "PROX_DEPLOY_VM_TYPES_JSON": '["srvarr"]',
            "PROX_DEPLOY_PASS": "/nix/store/pass/bin/pass",
        },
        stderr=io.StringIO(),
        password_store=passwords,
        deployer=deployer,
    )

    assert status == 0
    assert len(deployer.deployments) == 1


@pytest.mark.parametrize(
    ("environment", "message"),
    [
        ({}, "missing packaged setting PROX_DEPLOY_VM_TYPES_JSON"),
        (
            {
                "PROX_DEPLOY_VM_TYPES_JSON": "not-json",
                "PROX_DEPLOY_PASS": "pass",
            },
            "Expecting value",
        ),
    ],
)
def test_packaged_main_reports_invalid_settings(environment: dict[str, str], message: str) -> None:
    stderr = io.StringIO()

    status = main([], environment=environment, stderr=stderr)

    assert status == 1
    assert message in stderr.getvalue()


def test_cli_rejects_unknown_vm_types() -> None:
    with pytest.raises(SystemExit) as error:
        run_cli(
            ["unknown", "prx1-lab"],
            vm_types=["srvarr"],
            password_store=FakePasswordStore("unused"),
            deployer=RecordingDeployer(),
            stderr=io.StringIO(),
        )

    assert error.value.code == 2
