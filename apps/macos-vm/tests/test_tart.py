import hashlib
import io
import json
import os
import subprocess
from collections.abc import Sequence
from pathlib import Path
from threading import Event

import pytest
from fleet_macos_vm.process import Cancelled, Result
from fleet_macos_vm.state import Guest, Image
from fleet_macos_vm.tart import Tart, check_host, configure_ssh, progress, verified_restore

RESTORE = b"test restore contents"
IMAGE = Image(
    version="27.2",
    build="test",
    url="https://example.invalid/restore.ipsw",
    sha256=hashlib.sha256(RESTORE).hexdigest(),
    recipe=1,
)


class FakeChild:
    def __init__(self) -> None:
        self.returncode: int | None = None
        self.exit_on_wait: int | None = None
        self.killed = False

    def poll(self) -> int | None:
        return self.returncode

    def wait(self, timeout: float | None = None) -> int:
        if self.returncode is None:
            self.returncode = self.exit_on_wait
        if self.returncode is None:
            raise subprocess.TimeoutExpired("guest", timeout)
        return self.returncode

    def kill(self) -> None:
        self.killed = True
        self.returncode = -9


class GuestCommands:
    """Small VM model behind the process boundary; no subprocess monkeypatches."""

    def __init__(self, root: Path) -> None:
        self.root = root
        self.cancelled = Event()
        self.child = FakeChild()
        self.downloads = 0
        self.installed_key = b""
        self.sudo_password = b""
        self.shutdown_result = Result(0, "", "")
        self.shutdown_status: int | None = 0
        self.forced_stop = False
        self.interrupt_when_ready = False
        self.fail_boot = False
        self.machine_state = "stopped"
        self.machine_name = "test"

    def check_cancelled(self) -> None:
        if self.cancelled.is_set():
            raise Cancelled

    def start(self, arguments: Sequence[str]) -> FakeChild:
        self.child = FakeChild()
        if self.fail_boot:
            self.child.returncode = 1
        return self.child

    def run(
        self,
        arguments: Sequence[str],
        *,
        timeout: float = 30,
        input_data: bytes | None = None,
        capture: bool = True,
        cancellable: bool = True,
    ) -> Result:
        if cancellable:
            self.check_cancelled()
        program = arguments[0]
        if program == "curl":
            self.downloads += 1
            Path(arguments[arguments.index("--output") + 1]).write_bytes(RESTORE)
        elif program == "ssh-keygen":
            key = Path(arguments[arguments.index("-f") + 1])
            key.write_text("private key")
            key.with_suffix(".pub").write_bytes(b"ssh-ed25519 test-public-key")
        elif program in ("ssh", "sshpass"):
            command = arguments[-1]
            if "authorized_keys" in command:
                self.installed_key = input_data or b""
            elif "shutdown" in command:
                self.sudo_password = input_data or b""
                self.child.exit_on_wait = self.shutdown_status
                return self.shutdown_result
            elif self.interrupt_when_ready:
                self.cancelled.set()
        elif program == "tart":
            return self._tart(arguments)
        else:
            raise AssertionError(f"unsupported fake executable {program}")
        return Result(0, "", "")

    def _tart(self, arguments: Sequence[str]) -> Result:
        action = arguments[1]
        if action == "ip":
            return Result(0, "192.168.64.2\n", "")
        if action == "list":
            return Result(
                0, json.dumps([{"Name": self.machine_name, "State": self.machine_state}]), ""
            )
        if action == "stop":
            self.forced_stop = True
            self.child.returncode = 0
        elif action == "create":
            (self.root / "tart/vms" / arguments[-1]).mkdir(parents=True)
        elif action == "delete":
            (self.root / "tart/vms" / arguments[-1]).rmdir()
        elif action == "clone":
            (self.root / "tart/vms" / arguments[-1]).mkdir(parents=True)
        return Result(0, "", "")


def new_guest(root: Path) -> Guest:
    guest = Guest("test", root / "guest")
    guest.credentials.mkdir(parents=True)
    (guest.credentials / "password").write_text("temporary-password\n")
    return guest


@pytest.mark.parametrize("ssh_status", [0, 255])
def test_prepare_proves_key_login_and_shutdown(tmp_path: Path, ssh_status: int) -> None:
    commands = GuestCommands(tmp_path)
    commands.shutdown_result = Result(ssh_status, "", "")
    guest = new_guest(tmp_path)
    backend = Tart(tmp_path, commands)
    backend.prepare_base(guest, IMAGE)
    assert commands.installed_key == (guest.credentials / "id_ed25519.pub").read_bytes()
    assert commands.sudo_password == (guest.credentials / "password").read_bytes()
    assert commands.child.returncode == 0
    assert not commands.child.killed
    assert not commands.forced_stop
    assert (guest.credentials / "password").stat().st_mode & 0o777 == 0o600


@pytest.mark.parametrize("ssh_status", [0, 255])
def test_interrupt_after_readiness_requests_guest_shutdown(tmp_path: Path, ssh_status: int) -> None:
    commands = GuestCommands(tmp_path)
    commands.shutdown_result = Result(ssh_status, "", "")
    commands.interrupt_when_ready = True
    assert Tart(tmp_path, commands).run(new_guest(tmp_path), gui=True) == 130
    assert commands.sudo_password == b"temporary-password\n"
    assert commands.child.returncode == 0
    assert not commands.child.killed
    assert not commands.forced_stop


@pytest.mark.parametrize(
    ("ssh_result", "guest_status", "error"),
    [
        (Result(1, "", "sudo refused"), None, "sudo refused"),
        (Result(0, "", ""), None, "macOS did not finish shutting down"),
        (Result(255, "", "Connection closed by remote host"), None, "Connection closed"),
        (Result(255, "", "Permission denied"), None, "Permission denied"),
        (Result(255, "", "Connection closed by remote host"), 1, "Tart failed"),
        (Result(0, "", ""), 1, "Tart failed"),
    ],
)
def test_shutdown_failure_is_reported_and_guest_is_stopped(
    tmp_path: Path, ssh_result: Result, guest_status: int | None, error: str
) -> None:
    commands = GuestCommands(tmp_path)
    commands.interrupt_when_ready = True
    commands.shutdown_result = ssh_result
    commands.shutdown_status = guest_status
    with pytest.raises((RuntimeError, TimeoutError), match=error):
        Tart(tmp_path, commands).run(new_guest(tmp_path), gui=False)
    assert commands.child.returncode is not None
    assert commands.forced_stop == (guest_status is None)


def test_boot_failure_does_not_report_ready(tmp_path: Path) -> None:
    commands = GuestCommands(tmp_path)
    commands.fail_boot = True
    with pytest.raises(RuntimeError, match="exited before SSH"):
        Tart(tmp_path, commands).run(new_guest(tmp_path), gui=False)


def test_readiness_deadline_stops_unfinished_guest(tmp_path: Path) -> None:
    commands = GuestCommands(tmp_path)
    with pytest.raises(TimeoutError, match="SSH was not ready"):
        Tart(tmp_path, commands, boot_timeout=0).run(new_guest(tmp_path), gui=False)
    assert commands.child.returncode == 0


def test_restore_is_verified_and_reused(tmp_path: Path) -> None:
    commands = GuestCommands(tmp_path)
    path = verified_restore(commands, tmp_path, IMAGE)
    assert path.read_bytes() == RESTORE
    assert verified_restore(commands, tmp_path, IMAGE) == path
    assert commands.downloads == 1


def test_corrupt_cached_image_is_discarded(tmp_path: Path) -> None:
    commands = GuestCommands(tmp_path)
    path = tmp_path / f"{IMAGE.sha256}.ipsw"
    path.write_bytes(b"corrupt")
    with pytest.raises(RuntimeError, match="SHA-256 mismatch"):
        verified_restore(commands, tmp_path, IMAGE)
    assert not path.exists()
    assert verified_restore(commands, tmp_path, IMAGE).read_bytes() == RESTORE


def test_running_vm_cannot_be_deleted(tmp_path: Path) -> None:
    commands = GuestCommands(tmp_path)
    guest = new_guest(tmp_path)
    backend = Tart(tmp_path, commands)
    backend.clone(guest, guest)
    assert backend.exists(guest)
    commands.machine_state = "running"
    with pytest.raises(RuntimeError, match="stop it before resetting"):
        backend.delete(guest)
    assert backend.exists(guest)
    commands.machine_state = "stopped"
    backend.delete(guest)
    assert not backend.exists(guest)


@pytest.mark.parametrize(
    ("system", "machine", "version"),
    [
        ("Linux", "aarch64", ""),
        ("Darwin", "x86_64", "27.2"),
        ("Darwin", "arm64", "26.5"),
    ],
)
def test_unsupported_host_is_rejected(system: str, machine: str, version: str) -> None:
    with pytest.raises(RuntimeError, match="requires"):
        check_host(system, machine, version)


def test_supported_host_is_accepted() -> None:
    check_host("Darwin", "arm64", "27.2")


def test_ssh_config_is_accepted_by_openssh_with_spaces_and_percent(tmp_path: Path) -> None:
    guest = new_guest(tmp_path / 'space percent% quote"')
    configure_ssh(guest, "192.168.64.2")
    result = subprocess.run(
        ["ssh", "-G", "-F", str(guest.ssh_config), "macos-vm"],
        capture_output=True,
        text=True,
        check=True,
    )
    assert "hostname 192.168.64.2" in result.stdout
    assert "identityagent none" in result.stdout
    assert "batchmode yes" in result.stdout


def test_invalid_ssh_address_and_path_are_rejected(tmp_path: Path) -> None:
    with pytest.raises(ValueError):
        configure_ssh(new_guest(tmp_path), "address\nProxyCommand bad")
    with pytest.raises(ValueError, match="line breaks"):
        configure_ssh(new_guest(tmp_path / "line\nbreak"), "192.168.64.2")


def test_progress_survives_a_disconnected_terminal() -> None:
    reader, writer = os.pipe()
    os.close(reader)
    with io.TextIOWrapper(os.fdopen(writer, "wb", buffering=0), write_through=True) as stream:
        progress("Shutting down macOS…", stream=stream)
