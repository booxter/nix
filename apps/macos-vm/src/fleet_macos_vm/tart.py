from __future__ import annotations

import hashlib
import ipaddress
import secrets
import shlex
import subprocess
import time
from pathlib import Path

from atomic_file_writes import write_text_atomic
from fleet_macos_vm.process import Child, CommandRunner, Result
from fleet_macos_vm.state import Guest, Image
from pydantic import BaseModel, Field, TypeAdapter

BOOT_TIMEOUT = 300
SHUTDOWN_TIMEOUT = 45
USERNAME = "vmadmin"
INSTALL_KEY = 'umask 077; mkdir -p "$HOME/.ssh"; cat > "$HOME/.ssh/authorized_keys"'
SHUTDOWN = "sudo -S -p '' /sbin/shutdown -h now"


class VmInfo(BaseModel):
    name: str = Field(alias="Name")
    state: str = Field(alias="State")


def check_host(system: str, machine: str, version: str) -> None:
    if system != "Darwin" or machine != "arm64":
        raise RuntimeError("the macos target requires an Apple silicon Mac running macOS 27+")
    if int(version.split(".")[0]) < 27:
        raise RuntimeError("native macOS provisioning requires macOS 27+ on the host")


def ssh_path(path: Path) -> str:
    value = str(path)
    if "\n" in value or "\r" in value:
        raise ValueError("VM state paths cannot contain line breaks")
    # OpenSSH expands percent tokens even inside quoted path arguments.
    value = value.replace("%", "%%").replace("\\", "\\\\").replace('"', '\\"')
    return f'"{value}"'


def configure_ssh(guest: Guest, address: str) -> None:
    address = str(ipaddress.ip_address(address))
    write_text_atomic(
        guest.ssh_config,
        f"""Host macos-vm
    HostName {address}
    HostKeyAlias macos-vm
    User {USERNAME}
    IdentityFile {ssh_path(guest.credentials / "id_ed25519")}
    IdentityAgent none
    IdentitiesOnly yes
    UserKnownHostsFile {ssh_path(guest.credentials / "known_hosts")}
    StrictHostKeyChecking yes
    BatchMode yes
    ConnectTimeout 5
    ServerAliveInterval 10
    ServerAliveCountMax 2
""",
    )


def verified_restore(commands: CommandRunner, directory: Path, image: Image) -> Path:
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    destination = directory / f"{image.sha256}.ipsw"
    partial = destination.with_suffix(".part")
    candidate = destination
    if not destination.exists():
        print(f"Downloading macOS {image.version} ({image.build}) from Apple…", flush=True)
        result = commands.run(
            [
                "curl",
                "--fail",
                "--location",
                "--proto",
                "=https",
                "--proto-redir",
                "=https",
                "--continue-at",
                "-",
                "--output",
                str(partial),
                image.url,
            ],
            timeout=7200,
            capture=False,
        )
        result.require_success("downloading the Apple restore image")
        candidate = partial

    print("Verifying the restore image…", flush=True)
    digest = hashlib.sha256()
    with candidate.open("rb") as handle:
        while chunk := handle.read(8 * 1024 * 1024):
            commands.check_cancelled()
            digest.update(chunk)
    if digest.hexdigest() != image.sha256:
        candidate.unlink()
        raise RuntimeError("restore image SHA-256 mismatch; discarded the invalid download")
    if candidate != destination:
        candidate.replace(destination)
    return destination


class Tart:
    def __init__(
        self, root: Path, commands: CommandRunner, *, boot_timeout: float = BOOT_TIMEOUT
    ) -> None:
        self.root = root
        self.commands = commands
        self.boot_timeout = boot_timeout

    def exists(self, guest: Guest) -> bool:
        return (self.root / "tart" / "vms" / guest.name).exists()

    def delete(self, guest: Guest) -> None:
        result = self.commands.run(["tart", "list", "--format", "json"])
        result.require_success("checking VM state")
        machines = TypeAdapter(list[VmInfo]).validate_json(result.stdout)
        if any(vm.name == guest.name and vm.state != "stopped" for vm in machines):
            raise RuntimeError(f"{guest.name} is running or suspended; stop it before resetting")
        self.commands.run(["tart", "delete", guest.name]).require_success("deleting the VM")

    def clone(self, base: Guest, guest: Guest) -> None:
        print("Cloning the prepared macOS base…", flush=True)
        self.commands.run(["tart", "clone", base.name, guest.name], timeout=300).require_success(
            "cloning the prepared base"
        )

    def prepare_base(self, guest: Guest, image: Image) -> None:
        restore = verified_restore(self.commands, self.root / "images", image)
        self._create_credentials(guest)
        print("Restoring macOS; this can take several minutes…", flush=True)
        self.commands.run(
            ["tart", "create", "--from-ipsw", str(restore), "--disk-size", "50", guest.name],
            timeout=1800,
            capture=False,
        ).require_success("restoring macOS (the host login keychain must be unlocked)")
        self.commands.run(
            ["tart", "set", guest.name, "--cpu", "4", "--memory", "4096"]
        ).require_success("setting VM resources")

        password = (guest.credentials / "password").read_text().strip()
        provisioning = (
            f"fullName=VM Administrator,username={USERNAME},password={password},"
            "logsInAutomatically=false,enablesRemoteLogin=true"
        )
        child = self.commands.start(
            [
                *self._boot_arguments(guest, gui=False),
                f"--provisioning-opts={provisioning}",
            ]
        )
        try:
            self._wait_for_ssh(guest, child, password=True)
            self._ssh(
                guest,
                INSTALL_KEY,
                password=True,
                input_data=(guest.credentials / "id_ed25519.pub").read_bytes(),
            ).require_success("installing the VM SSH public key")
            self._ssh(guest, "true").require_success("verifying key-based SSH")
            self._shutdown(guest, child)
        finally:
            self._stop_remaining(guest, child)

    def run(self, guest: Guest, *, gui: bool) -> int:
        child = self.commands.start(self._boot_arguments(guest, gui=gui))
        try:
            self._wait_for_ssh(guest, child)
            print(f"Ready: ssh -F {shlex.quote(str(guest.ssh_config))} macos-vm", flush=True)
            print(
                "Ctrl-C shuts down the VM; its disk is retained. --reset macos starts fresh.",
                flush=True,
            )
            while child.poll() is None:
                if self.commands.cancelled.wait(0.2):
                    print("Shutting down macOS…", flush=True)
                    self._shutdown(guest, child)
                    return 130
            return child.wait()
        finally:
            self._stop_remaining(guest, child)

    def _create_credentials(self, guest: Guest) -> None:
        write_text_atomic(guest.credentials / "password", secrets.token_hex(24) + "\n", mode=0o600)
        self.commands.run(
            [
                "ssh-keygen",
                "-q",
                "-t",
                "ed25519",
                "-N",
                "",
                "-f",
                str(guest.credentials / "id_ed25519"),
            ]
        ).require_success("creating the VM SSH key")

    @staticmethod
    def _boot_arguments(guest: Guest, *, gui: bool) -> list[str]:
        arguments = ["tart", "run", "--no-audio", "--no-clipboard"]
        if not gui:
            arguments.append("--no-graphics")
        return [*arguments, guest.name]

    def _ssh(
        self,
        guest: Guest,
        command: str,
        *,
        password: bool = False,
        input_data: bytes | None = None,
        cancellable: bool = True,
    ) -> Result:
        arguments = ["ssh", "-F", str(guest.ssh_config)]
        if password:
            arguments = [
                "sshpass",
                "-f",
                str(guest.credentials / "password"),
                *arguments,
                "-o",
                "BatchMode=no",
                "-o",
                "PubkeyAuthentication=no",
                "-o",
                "PreferredAuthentications=password",
                "-o",
                "NumberOfPasswordPrompts=1",
                "-o",
                "StrictHostKeyChecking=accept-new",
            ]
        return self.commands.run(
            [*arguments, "macos-vm", command],
            input_data=input_data,
            timeout=15,
            cancellable=cancellable,
        )

    def _wait_for_ssh(
        self,
        guest: Guest,
        child: Child,
        *,
        password: bool = False,
    ) -> None:
        deadline = time.monotonic() + self.boot_timeout
        last_error = "no DHCP address yet"
        while time.monotonic() < deadline:
            self.commands.check_cancelled()
            if child.poll() is not None:
                raise RuntimeError(f"Tart exited before SSH was ready (status {child.returncode})")
            address = self.commands.run(["tart", "ip", guest.name], timeout=10)
            if address.code == 0 and address.stdout.strip():
                configure_ssh(guest, address.stdout.strip())
                try:
                    result = self._ssh(guest, "true", password=password)
                    if result.code == 0:
                        return
                    last_error = result.stderr.strip()
                except TimeoutError as error:
                    last_error = str(error)
            self.commands.cancelled.wait(1)
        raise TimeoutError(f"SSH was not ready after {self.boot_timeout:g} seconds: {last_error}")

    def _shutdown(self, guest: Guest, child: Child) -> None:
        self._ssh(
            guest,
            SHUTDOWN,
            input_data=(guest.credentials / "password").read_bytes(),
            cancellable=False,
        ).require_success("requesting guest shutdown")
        try:
            code = child.wait(timeout=SHUTDOWN_TIMEOUT)
        except subprocess.TimeoutExpired as error:
            raise TimeoutError("macOS did not finish shutting down") from error
        if code:
            raise RuntimeError(f"Tart failed during guest shutdown (status {code})")

    def _stop_remaining(self, guest: Guest, child: Child) -> None:
        if child.poll() is not None:
            return
        print("Stopping the unfinished VM session…", flush=True)
        try:
            self.commands.run(
                ["tart", "stop", "--timeout", "10", guest.name],
                timeout=20,
                capture=False,
                cancellable=False,
            )
        finally:
            if child.poll() is None:
                child.kill()
            child.wait()
