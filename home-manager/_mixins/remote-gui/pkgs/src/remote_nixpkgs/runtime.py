import os
import shlex
import shutil
import socket
import stat
import subprocess
import time
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import NoReturn, Protocol


class RunError(Exception):
    """The requested remote application could not be run safely."""


@dataclass(frozen=True)
class CommandResult:
    returncode: int
    stdout: str = ""
    stderr: str = ""


class ProcessController(Protocol):
    def run(self, arguments: Sequence[str]) -> CommandResult: ...

    def replace(
        self,
        arguments: Sequence[str],
        environment: Mapping[str, str] | None = None,
    ) -> NoReturn: ...


class SystemProcessController:
    def run(self, arguments: Sequence[str]) -> CommandResult:
        completed = subprocess.run(
            arguments,
            check=False,
            capture_output=True,
            text=True,
        )
        return CommandResult(completed.returncode, completed.stdout, completed.stderr)

    def replace(
        self,
        arguments: Sequence[str],
        environment: Mapping[str, str] | None = None,
    ) -> NoReturn:
        executable = shutil.which(arguments[0])
        if executable is None:
            raise RunError(f"executable is not available: {arguments[0]}")
        process_environment = os.environ if environment is None else environment
        os.execve(executable, list(arguments), dict(process_environment))


class RemoteSession(Protocol):
    @property
    def host(self) -> str: ...

    def run(
        self,
        arguments: Sequence[str],
        environment: Mapping[str, str] | None = None,
    ) -> CommandResult: ...

    def replace(self, arguments: Sequence[str]) -> NoReturn: ...


def _remote_command(
    arguments: Sequence[str],
    environment: Mapping[str, str] | None = None,
) -> str:
    command = list(arguments)
    if environment:
        command = ["env", *(f"{name}={value}" for name, value in environment.items()), *command]
    return shlex.join(command)


@dataclass(frozen=True)
class OpenSshSession:
    process: ProcessController
    host: str
    options: tuple[str, ...] = ()
    forwarding: str = "-X"

    def option_arguments(self) -> list[str]:
        return [argument for option in self.options for argument in ("-o", option)]

    def run(
        self,
        arguments: Sequence[str],
        environment: Mapping[str, str] | None = None,
    ) -> CommandResult:
        return self.process.run(
            [
                "ssh",
                *self.option_arguments(),
                self.host,
                _remote_command(arguments, environment),
            ]
        )

    def replace(self, arguments: Sequence[str]) -> NoReturn:
        self.process.replace(
            [
                "ssh",
                self.forwarding,
                *self.option_arguments(),
                self.host,
                _remote_command(arguments),
            ]
        )


@dataclass(frozen=True)
class WaylandDisplay:
    runtime_directory: Path
    name: str

    @property
    def socket_path(self) -> Path:
        return self.runtime_directory / self.name


@dataclass(frozen=True)
class CocoaWaySettings:
    launchctl: str = "/bin/launchctl"
    service: str = "org.nixos.cocoa-way"
    attempts: int = 100
    delay: float = 0.1


class CocoaWayManager:
    def __init__(
        self,
        process: ProcessController,
        *,
        settings: CocoaWaySettings,
        uid: int,
        notify: Callable[[str], None],
        sleep: Callable[[float], None] = time.sleep,
    ) -> None:
        self.process = process
        self.settings = settings
        self.uid = uid
        self.notify = notify
        self.sleep = sleep

    @staticmethod
    def _is_live_socket(path: Path) -> bool:
        try:
            if not stat.S_ISSOCK(path.stat().st_mode):
                return False
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
                client.settimeout(1)
                client.connect(str(path))
            return True
        except OSError:
            return False

    @classmethod
    def discover(cls, environment: Mapping[str, str]) -> WaylandDisplay | None:
        runtime = environment.get("XDG_RUNTIME_DIR")
        display = environment.get("WAYLAND_DISPLAY")
        if runtime and display:
            configured = WaylandDisplay(Path(runtime), display)
            if cls._is_live_socket(configured.socket_path):
                return configured

        candidates: list[Path] = []
        cocoa_runtime = environment.get("COCOA_WAY_RUNTIME_DIR")
        if cocoa_runtime:
            candidates.append(Path(cocoa_runtime))
        if runtime:
            candidates.append(Path(runtime))
        temporary = environment.get("TMPDIR")
        if temporary:
            candidates.append(Path(temporary) / "cocoa-way")
        candidates.append(Path("/tmp/cocoa-way"))

        visited: set[Path] = set()
        for directory in candidates:
            if directory in visited:
                continue
            visited.add(directory)
            try:
                sockets = sorted(directory.glob("wayland-*"))
            except OSError:
                continue
            for socket_path in sockets:
                if cls._is_live_socket(socket_path):
                    return WaylandDisplay(directory, socket_path.name)
        return None

    def ensure(self, environment: Mapping[str, str]) -> WaylandDisplay:
        display = self.discover(environment)
        if display is not None:
            self.notify(f"Using Cocoa-Way socket: {display.socket_path}")
            return display

        self.notify("Starting Cocoa-Way through launchd...")
        target = f"gui/{self.uid}/{self.settings.service}"
        result = self.process.run([self.settings.launchctl, "kickstart", target])
        if result.returncode != 0:
            raise RunError(
                f"Unable to start Cocoa-Way through launchd service {self.settings.service}.\n"
                "Activate host.remoteGui.wayland, or start Cocoa-Way manually."
            )

        for attempt in range(self.settings.attempts):
            display = self.discover(environment)
            if display is not None:
                self.notify(f"Using Cocoa-Way socket: {display.socket_path}")
                return display
            if attempt + 1 < self.settings.attempts:
                self.sleep(self.settings.delay)

        raise RunError(
            "Timed out waiting for the Cocoa-Way socket.\n"
            f"Inspect it with: launchctl print gui/{self.uid}/{self.settings.service}"
        )


@dataclass(frozen=True)
class WaypipeSession:
    ssh: OpenSshSession
    process: ProcessController
    cocoa_way: CocoaWayManager
    environment: Mapping[str, str]
    executable: str | None = None
    remote_executable: str = "waypipe"
    compression: str = "zstd"
    find_executable: Callable[[str], str | None] = shutil.which

    @property
    def host(self) -> str:
        return self.ssh.host

    def run(
        self,
        arguments: Sequence[str],
        environment: Mapping[str, str] | None = None,
    ) -> CommandResult:
        return self.ssh.run(arguments, environment)

    def replace(self, arguments: Sequence[str]) -> NoReturn:
        display = self.cocoa_way.ensure(self.environment)
        executable = self.executable or self.find_executable("waypipe")
        if executable is None:
            raise RunError("waypipe-darwin is not installed or not available in PATH.")
        environment = dict(self.environment)
        environment["XDG_RUNTIME_DIR"] = str(display.runtime_directory)
        environment["WAYLAND_DISPLAY"] = display.name
        self.process.replace(
            [
                executable,
                "--no-gpu",
                f"--compress={self.compression}",
                "--remote-bin",
                self.remote_executable,
                "ssh",
                "-o",
                "StreamLocalBindUnlink=yes",
                *self.ssh.option_arguments(),
                self.host,
                _remote_command(arguments),
            ],
            environment,
        )
