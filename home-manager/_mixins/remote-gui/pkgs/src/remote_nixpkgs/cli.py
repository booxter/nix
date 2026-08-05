import argparse
import os
import shutil
import sys
from collections.abc import Callable, Mapping, Sequence
from enum import StrEnum
from typing import NoReturn, TextIO

from remote_nixpkgs.runner import RemoteNixpkgsRunner, RunOptions, normalize_flake_ref
from remote_nixpkgs.runtime import (
    CocoaWayManager,
    CocoaWaySettings,
    OpenSshSession,
    ProcessController,
    RemoteSession,
    RunError,
    SystemProcessController,
    WaypipeSession,
)


class Transport(StrEnum):
    X11 = "x11"
    WAYPIPE = "waypipe"


class UsageError(Exception):
    """Command-line arguments are invalid."""


class ArgumentParser(argparse.ArgumentParser):
    def error(self, message: str) -> NoReturn:
        raise UsageError(message)


def _parser(program: str, transport: Transport) -> ArgumentParser:
    transport_description = (
        "SSH X11 forwarding" if transport is Transport.X11 else "Cocoa-Way and Waypipe"
    )
    parser = ArgumentParser(
        prog=program,
        description=f"Build a Linux package remotely and run it through {transport_description}.",
    )
    parser.add_argument("--host", default=None, help="SSH host to build and run on")
    parser.add_argument("--cmd", "--command", dest="command")
    parser.add_argument("--allow-unfree", action="store_true")
    parser.add_argument("--ssh-option", action="append", default=[])
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("source")
    parser.add_argument("package_attribute")
    parser.add_argument("program_arguments", nargs=argparse.REMAINDER)
    return parser


def _environment_bool(environment: Mapping[str, str], name: str) -> bool:
    return environment.get(name, "").lower() in {"1", "true", "yes"}


def main(
    transport: Transport,
    argv: Sequence[str] | None = None,
    *,
    program: str | None = None,
    environment: Mapping[str, str] | None = None,
    process: ProcessController | None = None,
    stdout: TextIO = sys.stdout,
    stderr: TextIO = sys.stderr,
    uid: int | None = None,
    find_executable: Callable[[str], str | None] = shutil.which,
) -> int:
    environ = os.environ if environment is None else environment
    program_name = program or ("xrun-nixpkgs" if transport is Transport.X11 else "wrun-nixpkgs")
    parser = _parser(program_name, transport)
    try:
        arguments = parser.parse_args(argv)
    except UsageError as error:
        print(f"{program_name}: {error}", file=stderr)
        print(parser.format_usage(), end="", file=stderr)
        return 64

    program_arguments = tuple(arguments.program_arguments)
    if program_arguments[:1] == ("--",):
        program_arguments = program_arguments[1:]
    host = arguments.host or environ.get("RUN_NIXPKGS_HOST", "frame")
    allow_unfree = arguments.allow_unfree or _environment_bool(environ, "RUN_NIXPKGS_ALLOW_UNFREE")
    options = RunOptions(
        flake_ref=normalize_flake_ref(arguments.source),
        package_attribute=arguments.package_attribute,
        command=arguments.command,
        allow_unfree=allow_unfree,
        program_arguments=program_arguments,
    )

    if arguments.dry_run:
        print(f"ssh host: {host}", file=stdout)
        print(f"transport: {transport}", file=stdout)
        if transport is Transport.X11:
            print("x11 forwarding: -Y", file=stdout)
        else:
            print(
                f"remote waypipe: {environ.get('WRUN_NIXPKGS_REMOTE_WAYPIPE', 'waypipe')}",
                file=stdout,
            )
        print(f"installable: {options.installable}", file=stdout)
        print(f"command: {options.command or 'auto'}", file=stdout)
        print(f"allow unfree: {str(options.allow_unfree).lower()}", file=stdout)
        return 0

    controller = process or SystemProcessController()
    ssh = OpenSshSession(
        controller,
        host,
        tuple(arguments.ssh_option),
    )
    if transport is Transport.X11:
        session: RemoteSession = ssh
    else:
        try:
            settings = CocoaWaySettings(
                launchctl=environ.get("WRUN_NIXPKGS_LAUNCHCTL", "/bin/launchctl"),
                service=environ.get("WRUN_NIXPKGS_COCOA_WAY_SERVICE", "org.nixos.cocoa-way"),
                attempts=int(environ.get("WRUN_NIXPKGS_START_ATTEMPTS", "100")),
                delay=float(environ.get("WRUN_NIXPKGS_START_DELAY", "0.1")),
            )
        except ValueError:
            print(f"{program_name}: invalid Cocoa-Way retry configuration", file=stderr)
            return 64
        manager = CocoaWayManager(
            controller,
            settings=settings,
            uid=os.getuid() if uid is None else uid,
            notify=lambda message: print(message, file=stderr),
        )
        session = WaypipeSession(
            ssh,
            controller,
            manager,
            environ,
            executable=environ.get("WRUN_NIXPKGS_WAYPIPE"),
            remote_executable=environ.get("WRUN_NIXPKGS_REMOTE_WAYPIPE", "waypipe"),
            compression=environ.get("WRUN_NIXPKGS_COMPRESS", "zstd"),
            find_executable=find_executable,
        )

    try:
        RemoteNixpkgsRunner(session, stderr=stderr).run(options)
    except RunError as error:
        print(f"{program_name}: {error}", file=stderr)
        return 1


def x11_main() -> int:
    return main(Transport.X11)


def waypipe_main() -> int:
    return main(Transport.WAYPIPE)
