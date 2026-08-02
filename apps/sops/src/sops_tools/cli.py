from __future__ import annotations

import argparse
import os
import platform
import socket
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Mapping, Protocol, Sequence

from .errors import ToolError
from .model import KeyPath
from .process import SubprocessRunner
from .repository import RuntimeEnvironment, SecretRepository
from .secrets import CommandSopsBackend, SecretService, SopsBackend


class SopsBackendFactory(Protocol):
    def create(self, environment: Mapping[str, str]) -> SopsBackend: ...


@dataclass(frozen=True)
class CommandBackendFactory:
    def create(self, environment: Mapping[str, str]) -> SopsBackend:
        return CommandSopsBackend(SubprocessRunner(environment))


@dataclass(frozen=True)
class Application:
    runtime: RuntimeEnvironment
    backend_factory: SopsBackendFactory = field(default_factory=CommandBackendFactory)

    @classmethod
    def discover(cls) -> Application:
        values = dict(os.environ)
        runtime = RuntimeEnvironment.discover(
            SubprocessRunner(),
            values=values,
            cwd=Path.cwd(),
            system_name=platform.system(),
            hostname=socket.gethostname().split(".", maxsplit=1)[0],
        )
        return cls(runtime)

    def secrets(self, explicit_domain: str | None) -> SecretService:
        domain = self.runtime.resolve_domain(explicit_domain)
        return SecretService(
            SecretRepository(self.runtime.repo_root, domain),
            self.backend_factory.create(self.runtime.command_environment(domain)),
        )


def _parser(description: str) -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=description)
    parser.add_argument(
        "--domain",
        help="secret domain (defaults to the current machine's inventory domain)",
    )
    return parser


def _run(command: Callable[[], int]) -> int:
    try:
        return command()
    except ToolError as error:
        print(error, file=sys.stderr)
        return 1


def cat_main(
    argv: Sequence[str] | None = None, *, application: Application | None = None
) -> int:
    def command() -> int:
        parser = _parser("Decrypt and print a host secret.")
        parser.add_argument("host", nargs="?")
        args = parser.parse_args(argv)
        current = application or Application.discover()
        host = args.host or current.runtime.hostname
        output = current.secrets(args.domain).cat(host)
        sys.stdout.write(output)
        return 0

    return _run(command)


def edit_main(
    argv: Sequence[str] | None = None, *, application: Application | None = None
) -> int:
    def command() -> int:
        parser = _parser("Edit a host secret with SOPS.")
        parser.add_argument("host", nargs="?")
        args = parser.parse_args(argv)
        current = application or Application.discover()
        host = args.host or current.runtime.hostname
        current.secrets(args.domain).edit(host)
        return 0

    return _run(command)


def set_main(
    argv: Sequence[str] | None = None, *, application: Application | None = None
) -> int:
    def command() -> int:
        parser = _parser("Set a host secret value from stdin.")
        parser.add_argument("host")
        parser.add_argument("key_path")
        args = parser.parse_args(argv)
        if sys.stdin.isatty():
            raise ToolError(
                "Refusing to read secret value from terminal; pipe or redirect the "
                "value on stdin."
            )
        service = (application or Application.discover()).secrets(args.domain)
        service.set_text(args.host, KeyPath.parse(args.key_path), sys.stdin.read())
        print(f"Updated {args.host}:{args.key_path}.")
        return 0

    return _run(command)


def copy_main(
    argv: Sequence[str] | None = None, *, application: Application | None = None
) -> int:
    def command() -> int:
        parser = _parser("Copy a value between host secrets.")
        parser.add_argument("source_host")
        parser.add_argument("destination_host")
        parser.add_argument("source_path")
        parser.add_argument("destination_path", nargs="?")
        args = parser.parse_args(argv)
        destination_path = args.destination_path or args.source_path
        service = (application or Application.discover()).secrets(args.domain)
        service.copy(
            args.source_host,
            args.destination_host,
            KeyPath.parse(args.source_path),
            KeyPath.parse(destination_path),
        )
        if args.source_path == destination_path:
            print(
                f"Copied {args.source_path} from {args.source_host} "
                f"to {args.destination_host}."
            )
        else:
            print(
                f"Copied {args.source_path} from {args.source_host} "
                f"to {args.destination_host}:{destination_path}."
            )
        return 0

    return _run(command)


def update_main(
    argv: Sequence[str] | None = None, *, application: Application | None = None
) -> int:
    def command() -> int:
        parser = _parser("Merge missing template values into a host secret.")
        parser.add_argument("--force", action="store_true")
        parser.add_argument("host", nargs="?")
        args = parser.parse_args(argv)
        current = application or Application.discover()
        host = args.host or current.runtime.hostname
        result = current.secrets(args.domain).update(host, force=args.force)
        if not result.changed:
            if os.environ.get("SOPS_UPDATE_QUIET") != "1":
                print(f"Secret already up to date: {result.secret}")
        elif args.force and result.reencrypted:
            print(f"Re-encrypted secret: {result.secret}")
        else:
            print(f"Updated secret from templates: {result.secret}")
        return 0

    return _run(command)
