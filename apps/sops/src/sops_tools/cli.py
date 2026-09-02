from __future__ import annotations

import argparse
import getpass
import os
import platform
import socket
import sys
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass, field
from pathlib import Path
from typing import Protocol

from .age import AgeRecipientResolver
from .bootstrap import (
    BootstrapService,
    CommandOperatorRecipientProvider,
    CommandRuntimeKeyProvider,
)
from .errors import ToolError
from .model import KeyPath
from .passwords import (
    CommandPasswordHasher,
    CommandPasswordStore,
    PasswordService,
)
from .process import SubprocessRunner
from .repository import RuntimeEnvironment, SecretRepository
from .secrets import CommandSopsBackend, SecretService, SopsBackend


class SopsBackendFactory(Protocol):
    def create(self, environment: Mapping[str, str], config: Path) -> SopsBackend: ...


@dataclass(frozen=True)
class CommandBackendFactory:
    def create(self, environment: Mapping[str, str], config: Path) -> SopsBackend:
        return CommandSopsBackend(SubprocessRunner(environment), config)


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

    def secrets(self, explicit_realm: str | None) -> SecretService:
        realm = self.runtime.resolve_realm(explicit_realm)
        return SecretService(
            SecretRepository(self.runtime.repo_root, realm),
            self.backend_factory.create(
                self.runtime.command_environment(realm),
                self.runtime.repo_root / ".sops.yaml",
            ),
        )


def _parser(description: str) -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=description)
    parser.add_argument(
        "--realm",
        help="realm (defaults to the current machine's inventory realm)",
    )
    return parser


def _run(command: Callable[[], int]) -> int:
    try:
        return command()
    except ToolError as error:
        print(error, file=sys.stderr)
        return 1


def cat_main(argv: Sequence[str] | None = None, *, application: Application | None = None) -> int:
    def command() -> int:
        parser = _parser("Decrypt and print a host secret.")
        parser.add_argument("host", nargs="?")
        args = parser.parse_args(argv)
        current = application or Application.discover()
        host = args.host or current.runtime.hostname
        output = current.secrets(args.realm).cat(host)
        sys.stdout.write(output)
        return 0

    return _run(command)


def edit_main(argv: Sequence[str] | None = None, *, application: Application | None = None) -> int:
    def command() -> int:
        parser = _parser("Edit a host secret with SOPS.")
        parser.add_argument("host", nargs="?")
        args = parser.parse_args(argv)
        current = application or Application.discover()
        host = args.host or current.runtime.hostname
        current.secrets(args.realm).edit(host)
        return 0

    return _run(command)


def set_main(argv: Sequence[str] | None = None, *, application: Application | None = None) -> int:
    def command() -> int:
        parser = _parser("Set a host secret value from stdin.")
        parser.add_argument("host")
        parser.add_argument("key_path")
        args = parser.parse_args(argv)
        if sys.stdin.isatty():
            raise ToolError(
                "Refusing to read secret value from terminal; pipe or redirect the value on stdin."
            )
        service = (application or Application.discover()).secrets(args.realm)
        service.set_text(args.host, KeyPath.parse(args.key_path), sys.stdin.read())
        print(f"Updated {args.host}:{args.key_path}.")
        return 0

    return _run(command)


def copy_main(argv: Sequence[str] | None = None, *, application: Application | None = None) -> int:
    def command() -> int:
        parser = _parser("Copy a value between host secrets.")
        parser.add_argument("source_host")
        parser.add_argument("destination_host")
        parser.add_argument("source_path")
        parser.add_argument("destination_path", nargs="?")
        args = parser.parse_args(argv)
        destination_path = args.destination_path or args.source_path
        service = (application or Application.discover()).secrets(args.realm)
        service.copy(
            args.source_host,
            args.destination_host,
            KeyPath.parse(args.source_path),
            KeyPath.parse(destination_path),
        )
        if args.source_path == destination_path:
            print(f"Copied {args.source_path} from {args.source_host} to {args.destination_host}.")
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
        result = current.secrets(args.realm).update(host, force=args.force)
        if not result.changed:
            if os.environ.get("SOPS_UPDATE_QUIET") != "1":
                print(f"Secret already up to date: {result.secret}")
        elif args.force and result.reencrypted:
            print(f"Re-encrypted secret: {result.secret}")
        else:
            print(f"Updated secret from templates: {result.secret}")
        return 0

    return _run(command)


def pass_main(argv: Sequence[str] | None = None, *, application: Application | None = None) -> int:
    def command() -> int:
        parser = _parser("Hash and store a host login password.")
        parser.add_argument("--gen", action="store_true")
        parser.add_argument("host")
        parser.add_argument("user", choices=("root", "ihrachyshka", "both"))
        args = parser.parse_args(argv)
        current = application or Application.discover()
        realm = current.runtime.resolve_realm(args.realm)
        environment = current.runtime.command_environment(realm)
        runner = SubprocessRunner(environment)
        backend = current.backend_factory.create(
            environment, current.runtime.repo_root / ".sops.yaml"
        )
        service = PasswordService(
            SecretRepository(current.runtime.repo_root, realm),
            backend,
            CommandPasswordStore(runner),
            CommandPasswordHasher(runner),
        )
        try:
            length = int(os.environ.get("SOPS_PASS_GENERATE_LENGTH", "32"))
        except ValueError as error:
            raise ToolError("SOPS_PASS_GENERATE_LENGTH must be an integer.") from error
        result = service.update(
            args.host,
            args.user,
            generate=args.gen,
            prefix=os.environ.get("SOPS_PASS_PREFIX", "host"),
            length=length,
        )
        if result.user == "both":
            print(
                "Updated users/root/hashedPassword and "
                f"users/ihrachyshka/hashedPassword in {result.secret}."
            )
        else:
            print(f"Updated users/{result.user}/hashedPassword in {result.secret}.")
        print(f"{result.action} {' and '.join(result.entries)}.")
        return 0

    return _run(command)


def bootstrap_main(
    argv: Sequence[str] | None = None, *, application: Application | None = None
) -> int:
    def command() -> int:
        parser = _parser("Bootstrap a host SOPS runtime key and encrypted secret.")
        parser.add_argument("--local", action="store_true")
        parser.add_argument("host")
        parser.add_argument("--user", default=os.environ.get("USER", getpass.getuser()))
        args = parser.parse_args(argv)
        current = application or Application.discover()
        realm = current.runtime.resolve_realm(args.realm, require_identity=False)
        environment = current.runtime.command_environment(realm)
        runner = SubprocessRunner(environment)
        service = BootstrapService(
            current.runtime,
            SecretRepository(current.runtime.repo_root, realm),
            current.backend_factory.create(environment, current.runtime.repo_root / ".sops.yaml"),
            CommandRuntimeKeyProvider(runner, current.runtime.repo_root),
            CommandOperatorRecipientProvider(current.runtime, runner, AgeRecipientResolver(runner)),
        )
        result = service.bootstrap(
            args.host,
            args.user,
            local=args.local,
            has_tty=sys.stdin.isatty(),
        )
        for message in result.messages:
            print(message)
        return 0

    return _run(command)
