from __future__ import annotations

import io
import sys
from collections.abc import Sequence
from dataclasses import dataclass, field
from pathlib import Path

import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from prox_deploy.adapters import (
    CommandResult,
    NixmoxerDeployer,
    PassPasswordStore,
    SubprocessRunner,
)
from prox_deploy.cli import load_vm_specs, main, run_cli
from prox_deploy.core import DeployRequest, ProxDeployError, ProxmoxCredentials, VmSpec
from prox_deploy.installer import SshGuestInstaller, SystemClock
from pydantic import TypeAdapter, ValidationError


@pytest.fixture
def identity() -> tuple[str, str]:
    key = Ed25519PrivateKey.generate()
    private = key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.OpenSSH,
        serialization.NoEncryption(),
    )
    public = key.public_key().public_bytes(
        serialization.Encoding.OpenSSH, serialization.PublicFormat.OpenSSH
    )
    return private.decode(), public.decode()


@dataclass
class MemoryPasswords:
    entries: dict[str, str]

    def read(self, reference: str) -> str:
        if reference not in self.entries:
            raise ProxDeployError(f"cannot read {reference}")
        return self.entries[reference]


@dataclass
class RecordingDeployer:
    deployments: list[tuple[DeployRequest, ProxmoxCredentials]] = field(default_factory=list)

    def deploy(self, request: DeployRequest, credentials: ProxmoxCredentials) -> int:
        self.deployments.append((request, credentials))
        return 123


@dataclass
class RecordingInstaller:
    identities: list[tuple[DeployRequest, int, bytes]] = field(default_factory=list)

    def prepare(self, request: DeployRequest) -> None:
        pass

    def install(self, request: DeployRequest, vmid: int, identity: bytes) -> None:
        self.identities.append((request, vmid, identity))


@dataclass
class StubRunner:
    responses: list[CommandResult]
    payloads: list[str] = field(default_factory=list)

    def run(
        self,
        arguments: Sequence[str],
        *,
        input_data: str | None = None,
        timeout: float | None = None,
    ) -> CommandResult:
        if input_data is not None:
            self.payloads.append(input_data)
        return self.responses.pop(0) if len(self.responses) > 1 else self.responses[0]


@dataclass
class FakeClock:
    elapsed: float = 0

    def now(self) -> float:
        return self.elapsed

    def sleep(self, seconds: float) -> None:
        self.elapsed += seconds


def specs(public: str) -> dict[str, VmSpec]:
    return {"srvarr": VmSpec(nodes=("prx1-lab", "prx2-lab"), public_key=public)}


def environment(public: str) -> dict[str, str]:
    return {
        "PROX_DEPLOY_VM_SPECS_JSON": TypeAdapter(dict[str, VmSpec])
        .dump_json(specs(public))
        .decode(),
        "PROX_DEPLOY_PASS": "pass",
        "PROX_DEPLOY_SSH": "ssh",
    }


def test_deploy_validates_identity_and_installs_the_created_vm(identity: tuple[str, str]) -> None:
    private, public = identity
    passwords = MemoryPasswords(
        {
            "host/prx1-lab/root": "api-password\n",
            "host/srvarr/ssh_host_ed25519_key": private,
        }
    )
    deployer = RecordingDeployer()
    installer = RecordingInstaller()
    errors = io.StringIO()

    assert (
        main(
            ["srvarr", "prx1-lab"],
            environment=environment(public),
            stderr=errors,
            password_store=passwords,
            deployer=deployer,
            installer=installer,
        )
        == 0
    )

    request = DeployRequest("srvarr", "prx1-lab")
    assert deployer.deployments == [
        (request, ProxmoxCredentials("prx1-lab", "root", "api-password"))
    ]
    assert installer.identities == [(request, 123, private.encode())]
    assert "Installed srvarr" in errors.getvalue()
    assert private not in errors.getvalue()


@pytest.mark.parametrize("private", [None, "invalid-private-key"])
def test_missing_or_invalid_identity_cannot_create_a_vm(
    identity: tuple[str, str],
    private: str | None,
) -> None:
    _, public = identity
    passwords = MemoryPasswords(
        {} if private is None else {"host/srvarr/ssh_host_ed25519_key": private}
    )
    deployer = RecordingDeployer()
    installer = RecordingInstaller()
    errors = io.StringIO()

    assert (
        run_cli(
            ["srvarr", "prx1-lab"],
            vm_specs=specs(public),
            password_store=passwords,
            deployer=deployer,
            installer=installer,
            stderr=errors,
        )
        == 1
    )
    assert deployer.deployments == []
    assert installer.identities == []


def test_wrong_identity_cannot_create_a_vm(identity: tuple[str, str]) -> None:
    private, _ = identity
    other = (
        Ed25519PrivateKey.generate()
        .public_key()
        .public_bytes(serialization.Encoding.OpenSSH, serialization.PublicFormat.OpenSSH)
        .decode()
    )
    errors = io.StringIO()
    deployer = RecordingDeployer()
    assert (
        run_cli(
            ["srvarr", "prx1-lab"],
            vm_specs=specs(other),
            password_store=MemoryPasswords({"host/srvarr/ssh_host_ed25519_key": private}),
            deployer=deployer,
            installer=RecordingInstaller(),
            stderr=errors,
        )
        == 1
    )
    assert "does not match" in errors.getvalue()
    assert deployer.deployments == []


def test_missing_guest_agent_permissions_cannot_create_a_vm(identity: tuple[str, str]) -> None:
    private, public = identity
    deployer = RecordingDeployer()
    runner = StubRunner([CommandResult(1, "", "permission denied")])
    errors = io.StringIO()
    installer = SshGuestInstaller(Path("ssh"), runner, FakeClock(), errors)

    assert (
        run_cli(
            ["srvarr", "prx1-lab"],
            vm_specs=specs(public),
            password_store=MemoryPasswords(
                {
                    "host/prx1-lab/root": "api-password",
                    "host/srvarr/ssh_host_ed25519_key": private,
                }
            ),
            deployer=deployer,
            installer=installer,
            stderr=errors,
        )
        == 1
    )
    assert deployer.deployments == []
    assert runner.payloads == []
    assert "permission denied" in errors.getvalue()


def test_node_outside_cluster_is_rejected_before_reading_secrets(identity: tuple[str, str]) -> None:
    _, public = identity
    errors = io.StringIO()
    assert (
        run_cli(
            ["srvarr", "nvws"],
            vm_specs=specs(public),
            password_store=MemoryPasswords({}),
            deployer=RecordingDeployer(),
            installer=RecordingInstaller(),
            stderr=errors,
        )
        == 1
    )
    assert "not in VM srvarr's cluster" in errors.getvalue()


def test_unknown_host_is_rejected(identity: tuple[str, str]) -> None:
    _, public = identity
    with pytest.raises(SystemExit) as error:
        run_cli(
            ["unknown", "prx1-lab"],
            vm_specs=specs(public),
            password_store=MemoryPasswords({}),
            deployer=RecordingDeployer(),
            installer=RecordingInstaller(),
            stderr=io.StringIO(),
        )
    assert error.value.code == 2


def test_pass_preserves_private_key_line_endings(identity: tuple[str, str]) -> None:
    private, _ = identity
    store = PassPasswordStore(Path("pass"), StubRunner([CommandResult(0, private, "")]))
    assert store.read("host/srvarr/ssh_host_ed25519_key") == private


@pytest.mark.parametrize(
    "result", [CommandResult(1, "", "entry missing"), CommandResult(0, "\n", "")]
)
def test_pass_failures_are_reported(result: CommandResult) -> None:
    store = PassPasswordStore(Path("pass"), StubRunner([result]))
    with pytest.raises(ProxDeployError):
        store.read("missing")


def test_command_runner_preserves_stdin_and_reports_failures(tmp_path: Path) -> None:
    runner = SubprocessRunner()
    result = runner.run(
        [sys.executable, "-c", "import sys; sys.stdout.write(sys.stdin.read())"],
        input_data="fixture\n",
    )
    assert result.stdout == "fixture\n"
    assert result.returncode == 0
    assert (
        runner.run([sys.executable, "-c", "import time; time.sleep(1)"], timeout=0.01).returncode
        == 124
    )
    with pytest.raises(ProxDeployError, match="cannot run"):
        runner.run([str(tmp_path / "missing")])


@pytest.mark.parametrize("fail", [False, True])
def test_nixmoxer_restores_credentials_after_creation_or_failure(fail: bool) -> None:
    values = {"PROXMOX_USER": "previous", "UNRELATED": "kept"}

    def callback(flake: bool, machine: str, node: str | None = None) -> object:
        assert values["PROXMOX_PASSWORD"] == "api-password"
        if fail:
            raise ProxDeployError("API unavailable")
        return 123

    deployer = NixmoxerDeployer(lambda: callback, values)
    request = DeployRequest("srvarr", "prx1-lab")
    credentials = ProxmoxCredentials("prx1-lab", "root", "api-password")
    if fail:
        with pytest.raises(ProxDeployError, match="API unavailable"):
            deployer.deploy(request, credentials)
    else:
        assert deployer.deploy(request, credentials) == 123
    assert values == {"PROXMOX_USER": "previous", "UNRELATED": "kept"}


@pytest.mark.parametrize("vmid", [None, True, 99])
def test_nixmoxer_requires_the_created_vm_id(vmid: object) -> None:
    def callback(flake: bool, machine: str, node: str | None = None) -> object:
        return vmid

    deployer = NixmoxerDeployer(lambda: callback, {})
    with pytest.raises(ProxDeployError, match="valid created VM ID"):
        deployer.deploy(
            DeployRequest("srvarr", "prx1-lab"), ProxmoxCredentials("prx1-lab", "root", "pw")
        )


def test_packaged_inventory_is_validated(identity: tuple[str, str]) -> None:
    _, public = identity
    assert load_vm_specs(environment(public)["PROX_DEPLOY_VM_SPECS_JSON"]) == specs(public)
    with pytest.raises(ValidationError):
        load_vm_specs('{"srvarr":{"nodes":[],"public_key":"fixture"}}')


@pytest.mark.parametrize("settings", [{}, {"PROX_DEPLOY_VM_SPECS_JSON": "invalid-json"}])
def test_invalid_packaged_settings_are_reported(settings: dict[str, str]) -> None:
    errors = io.StringIO()
    assert main([], environment=settings, stderr=errors) == 1
    assert errors.getvalue().startswith("prox-deploy:")


def test_packaged_main_constructs_real_adapters_for_help(identity: tuple[str, str]) -> None:
    _, public = identity
    with pytest.raises(SystemExit) as error:
        main(["--help"], environment=environment(public), stderr=io.StringIO())
    assert error.value.code == 0


def test_guest_installation_waits_for_agent_and_boot_and_preserves_payload() -> None:
    runner = StubRunner(
        [
            CommandResult(1, "", "not running"),
            CommandResult(0, "", ""),
            CommandResult(0, '{"exited":1,"exitcode":0}', ""),
            CommandResult(1, "inactive", ""),
            CommandResult(0, "active", ""),
        ]
    )
    clock = FakeClock()
    installer = SshGuestInstaller(Path("ssh"), runner, clock, io.StringIO())
    installer.install(DeployRequest("srvarr", "prx1-lab"), 123, b"fixture\n")
    assert runner.payloads == ["fixture\n"]
    assert clock.elapsed > 0


@pytest.mark.parametrize("allowed", [True, False])
def test_guest_agent_permissions_are_checked_without_delivering_a_key(allowed: bool) -> None:
    runner = StubRunner([CommandResult(0 if allowed else 1, "", "permission denied")])
    installer = SshGuestInstaller(Path("ssh"), runner, FakeClock(), io.StringIO())
    if allowed:
        installer.prepare(DeployRequest("srvarr", "prx1-lab"))
    else:
        with pytest.raises(ProxDeployError, match="cannot use the guest agent"):
            installer.prepare(DeployRequest("srvarr", "prx1-lab"))
    assert runner.payloads == []


@pytest.mark.parametrize(
    "response",
    [
        CommandResult(1, "", "SSH failed"),
        CommandResult(0, "not-json", ""),
        CommandResult(0, '{"exited":1,"exitcode":1,"err-data":"wrong identity"}', ""),
        CommandResult(0, '{"pid":123}', ""),
    ],
)
def test_guest_receiver_failures_are_reported(response: CommandResult) -> None:
    installer = SshGuestInstaller(
        Path("ssh"), StubRunner([CommandResult(0, "", ""), response]), FakeClock(), io.StringIO()
    )
    with pytest.raises(ProxDeployError):
        installer.install(DeployRequest("srvarr", "prx1-lab"), 123, b"fixture\n")


def test_agent_and_boot_waits_are_bounded() -> None:
    for responses in [
        [CommandResult(1, "", "agent unavailable")],
        [
            CommandResult(0, "", ""),
            CommandResult(0, '{"exited":1,"exitcode":0}', ""),
            CommandResult(1, "failed", ""),
        ],
    ]:
        installer = SshGuestInstaller(
            Path("ssh"), StubRunner(responses), FakeClock(), io.StringIO()
        )
        with pytest.raises(ProxDeployError, match="Waiting for"):
            installer.install(DeployRequest("srvarr", "prx1-lab"), 123, b"fixture\n")


def test_system_clock_tracks_elapsed_time() -> None:
    clock = SystemClock()
    before = clock.now()
    clock.sleep(0)
    assert clock.now() >= before
