import io
import shlex
import socket
from collections.abc import Mapping, Sequence
from pathlib import Path
from tempfile import TemporaryDirectory
from typing import NoReturn

import pytest

from remote_nixpkgs.cli import Transport, main
from remote_nixpkgs.runner import normalize_flake_ref
from remote_nixpkgs.runtime import CocoaWayManager, CocoaWaySettings, CommandResult


class ProgramReplaced(Exception):
    def __init__(self, arguments: Sequence[str], environment: Mapping[str, str] | None) -> None:
        self.arguments = tuple(arguments)
        self.environment = dict(environment or {})


class FakeProcessController:
    def __init__(self, results: Sequence[CommandResult] = ()) -> None:
        self.results = list(results)
        self.calls: list[tuple[str, ...]] = []

    def run(self, arguments: Sequence[str]) -> CommandResult:
        self.calls.append(tuple(arguments))
        if not self.results:
            raise AssertionError(f"unexpected process call: {arguments}")
        return self.results.pop(0)

    def replace(
        self,
        arguments: Sequence[str],
        environment: Mapping[str, str] | None = None,
    ) -> NoReturn:
        raise ProgramReplaced(arguments, environment)


class CocoaWayStartingProcess:
    def __init__(self, socket_path: Path) -> None:
        self.socket_path = socket_path
        self.calls: list[tuple[str, ...]] = []
        self.listener: socket.socket | None = None

    def run(self, arguments: Sequence[str]) -> CommandResult:
        self.calls.append(tuple(arguments))
        self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.listener.bind(str(self.socket_path))
        self.listener.listen()
        return CommandResult(0)

    def replace(
        self,
        arguments: Sequence[str],
        environment: Mapping[str, str] | None = None,
    ) -> NoReturn:
        raise AssertionError(f"unexpected process replacement: {arguments}, {environment}")

    def close(self) -> None:
        if self.listener is not None:
            self.listener.close()


def invoke(
    transport: Transport,
    arguments: Sequence[str],
    *,
    process: FakeProcessController | None = None,
    environment: Mapping[str, str] | None = None,
    find_executable: str | None = None,
    system: str = "linux",
) -> tuple[int, str, str]:
    stdout = io.StringIO()
    stderr = io.StringIO()
    status = main(
        transport,
        arguments,
        environment={} if environment is None else environment,
        process=process or FakeProcessController(),
        stdout=stdout,
        stderr=stderr,
        uid=501,
        find_executable=lambda _: find_executable,
        system=system,
    )
    return status, stdout.getvalue(), stderr.getvalue()


@pytest.mark.parametrize(
    ("source", "expected"),
    [
        ("538891", "github:NixOS/nixpkgs?ref=pull/538891/head"),
        ("#538891", "github:NixOS/nixpkgs?ref=pull/538891/head"),
        (
            "https://github.com/NixOS/nixpkgs/pull/538891/files",
            "github:NixOS/nixpkgs?ref=pull/538891/head",
        ),
        (
            "github.com/owner/repository/pull/42",
            "github:owner/repository?ref=pull/42/head",
        ),
        ("github:NixOS/nixpkgs/nixos-unstable", "github:NixOS/nixpkgs/nixos-unstable"),
    ],
)
def test_normalizes_pull_request_shortcuts(source: str, expected: str) -> None:
    assert normalize_flake_ref(source) == expected


def test_dry_run_describes_x11_and_waypipe_sessions() -> None:
    x11_status, x11_stdout, _ = invoke(
        Transport.X11,
        ["--allow-unfree", "--dry-run", "538891", "foot"],
    )
    wayland_status, wayland_stdout, _ = invoke(
        Transport.WAYPIPE,
        ["--host", "builder", "--dry-run", "nixpkgs", "foot"],
        environment={"WRUN_NIXPKGS_REMOTE_WAYPIPE": "remote-waypipe"},
    )

    assert x11_status == 0
    assert "x11 forwarding: -Y" in x11_stdout
    assert "allow unfree: true" in x11_stdout
    assert "github:NixOS/nixpkgs?ref=pull/538891/head#foot" in x11_stdout
    assert wayland_status == 0
    assert "ssh host: builder" in wayland_stdout
    assert "remote waypipe: remote-waypipe" in wayland_stdout


def test_rejects_invalid_arguments() -> None:
    missing_status, _, missing_stderr = invoke(Transport.X11, ["nixpkgs"])
    retry_status, _, retry_stderr = invoke(
        Transport.WAYPIPE,
        ["nixpkgs", "foot"],
        environment={"WRUN_NIXPKGS_START_ATTEMPTS": "many"},
    )

    assert missing_status == 64
    assert "required" in missing_stderr
    assert retry_status == 64
    assert "invalid Cocoa-Way retry configuration" in retry_stderr


def test_builds_and_runs_through_x11() -> None:
    process = FakeProcessController(
        [
            CommandResult(0, "/var/run/current-xquartz:0\n"),
            CommandResult(0, "/nix/store/example-foot\n", "build log\n"),
            CommandResult(0, "foot\n"),
            CommandResult(0),
        ]
    )

    with pytest.raises(ProgramReplaced) as replaced:
        invoke(
            Transport.X11,
            [
                "--allow-unfree",
                "--ssh-option",
                "ServerAliveInterval=10",
                "nixpkgs",
                "foot",
                "--",
                "--title",
                "two words",
            ],
            process=process,
            environment={"DISPLAY": "/var/run/stale-xquartz:0"},
            system="darwin",
        )

    assert process.calls[0] == ("/bin/launchctl", "getenv", "DISPLAY")
    build_command = shlex.split(process.calls[1][-1])
    assert build_command[:3] == ["env", "NIXPKGS_ALLOW_UNFREE=1", "nix"]
    assert "--impure" in build_command
    assert process.calls[1][:-1] == (
        "ssh",
        "-o",
        "ServerAliveInterval=10",
        "frame",
    )
    assert replaced.value.arguments[:-1] == (
        "ssh",
        "-Y",
        "-o",
        "ServerAliveInterval=10",
        "frame",
    )
    assert shlex.split(replaced.value.arguments[-1]) == [
        "/nix/store/example-foot/bin/foot",
        "--title",
        "two words",
    ]
    assert replaced.value.environment["DISPLAY"] == "/var/run/current-xquartz:0"


def test_x11_reports_an_unavailable_launchd_display() -> None:
    process = FakeProcessController([CommandResult(1)])

    status, _, stderr = invoke(
        Transport.X11,
        ["nixpkgs", "foot"],
        process=process,
        system="darwin",
    )

    assert status == 1
    assert "Unable to determine the current XQuartz display through launchd" in stderr


def test_falls_back_to_attribute_name_and_reports_available_executables() -> None:
    process = FakeProcessController(
        [
            CommandResult(0, "/nix/store/example\n"),
            CommandResult(1),
            CommandResult(1),
            CommandResult(0, "/nix/store/example/bin/other\n"),
        ]
    )

    status, _, stderr = invoke(
        Transport.X11,
        ["nixpkgs", "legacyPackages.x86_64-linux.example"],
        process=process,
    )

    assert status == 1
    assert "Tried: /nix/store/example/bin/example" in stderr
    assert "/nix/store/example/bin/other" in stderr


def test_reports_remote_build_failures() -> None:
    process = FakeProcessController([CommandResult(1, stderr="remote failure\n")])

    status, _, stderr = invoke(
        Transport.X11,
        ["nixpkgs", "foot"],
        process=process,
    )

    assert status == 1
    assert "remote failure" in stderr
    assert "nix build failed on frame" in stderr


def test_waypipe_uses_a_live_native_wayland_socket() -> None:
    with TemporaryDirectory(prefix="remote-gui-", dir="/tmp") as temporary:
        runtime_directory = Path(temporary)
        socket_path = runtime_directory / "wayland-7"
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
            listener.bind(str(socket_path))
            listener.listen()
            process = FakeProcessController(
                [
                    CommandResult(0, "/nix/store/example-foot\n"),
                    CommandResult(0, "foot\n"),
                    CommandResult(0),
                ]
            )

            with pytest.raises(ProgramReplaced) as replaced:
                invoke(
                    Transport.WAYPIPE,
                    ["nixpkgs", "foot"],
                    process=process,
                    environment={"COCOA_WAY_RUNTIME_DIR": str(runtime_directory)},
                    find_executable="/opt/homebrew/bin/waypipe",
                )

        assert replaced.value.arguments[:6] == (
            "/opt/homebrew/bin/waypipe",
            "--no-gpu",
            "--compress=zstd",
            "--remote-bin",
            "waypipe",
            "ssh",
        )
        assert replaced.value.environment["XDG_RUNTIME_DIR"] == str(runtime_directory)
        assert replaced.value.environment["WAYLAND_DISPLAY"] == "wayland-7"
        assert shlex.split(replaced.value.arguments[-1]) == [
            "env",
            "NIXOS_OZONE_WL=1",
            "XDG_SESSION_TYPE=wayland",
            "/nix/store/example-foot/bin/foot",
        ]


def test_waypipe_reports_an_unavailable_cocoa_way_agent() -> None:
    with TemporaryDirectory(prefix="remote-gui-", dir="/tmp") as temporary:
        runtime_directory = Path(temporary)
        stale_socket = runtime_directory / "wayland-1"
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        listener.bind(str(stale_socket))
        listener.close()
        process = FakeProcessController(
            [
                CommandResult(0, "/nix/store/example-foot\n"),
                CommandResult(0, "foot\n"),
                CommandResult(0),
                CommandResult(1),
            ]
        )

        status, _, stderr = invoke(
            Transport.WAYPIPE,
            ["nixpkgs", "foot"],
            process=process,
            environment={"COCOA_WAY_RUNTIME_DIR": str(runtime_directory)},
            find_executable="/opt/homebrew/bin/waypipe",
        )

        assert status == 1
        assert "Unable to start Cocoa-Way through launchd" in stderr
        assert "Activate host.remoteGui.wayland" in stderr
        assert process.calls[-1] == (
            "/bin/launchctl",
            "kickstart",
            "gui/501/org.nixos.cocoa-way",
        )


def test_cocoa_way_rediscovers_the_socket_after_starting_launchd() -> None:
    with TemporaryDirectory(prefix="remote-gui-", dir="/tmp") as temporary:
        runtime_directory = Path(temporary)
        process = CocoaWayStartingProcess(runtime_directory / "wayland-8")
        notifications: list[str] = []
        manager = CocoaWayManager(
            process,
            settings=CocoaWaySettings(attempts=2, delay=0),
            uid=501,
            notify=notifications.append,
            sleep=lambda _: None,
        )
        try:
            display = manager.ensure({"COCOA_WAY_RUNTIME_DIR": str(runtime_directory)})
        finally:
            process.close()

        assert display.socket_path == runtime_directory / "wayland-8"
        assert process.calls == [("/bin/launchctl", "kickstart", "gui/501/org.nixos.cocoa-way")]
        assert notifications == [
            "Starting Cocoa-Way through launchd...",
            f"Using Cocoa-Way socket: {runtime_directory}/wayland-8",
        ]


def test_waypipe_reports_when_its_launcher_is_missing() -> None:
    with TemporaryDirectory(prefix="remote-gui-", dir="/tmp") as temporary:
        runtime_directory = Path(temporary)
        socket_path = runtime_directory / "wayland-9"
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
            listener.bind(str(socket_path))
            listener.listen()
            process = FakeProcessController(
                [
                    CommandResult(0, "/nix/store/example-foot\n"),
                    CommandResult(0, "foot\n"),
                    CommandResult(0),
                ]
            )

            status, _, stderr = invoke(
                Transport.WAYPIPE,
                ["nixpkgs", "foot"],
                process=process,
                environment={"COCOA_WAY_RUNTIME_DIR": str(runtime_directory)},
            )

        assert status == 1
        assert "waypipe-darwin is not installed or not available in PATH" in stderr
