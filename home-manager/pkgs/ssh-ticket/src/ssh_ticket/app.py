#!/usr/bin/env python3
import argparse
import contextlib
import datetime as dt
import fcntl
import json
import os
import pathlib
import re
import sys
from collections.abc import Iterator, Sequence
from typing import NoReturn, cast

from atomic_file_writes import write_text_atomic
from pydantic import ValidationError

from .durations import (
    DurationError,
    format_duration as format_duration_value,
    parse_duration as parse_duration_value,
)
from .models import TARGETS, Target, TicketMetadata, TicketPaths, TicketStatus
from .runtime import CommandError, Runtime, system_runtime


DEFAULT_CA_PRIVATE_KEY = "~/.ssh/fleet-user-ca"
DEFAULT_CA_PUBLIC_KEY = "~/.ssh/fleet-user-ca.pub"
DEFAULT_KEY = "~/.ssh/fleet-ticket/id_ed25519"
TARGETS_FILE_ENV = "SSHT_TARGETS_FILE"
MIN_VALID_SECONDS = 60


class Error(Exception):
    pass


def parse_duration(value: int | str) -> int:
    try:
        return parse_duration_value(value)
    except DurationError as exc:
        raise Error(str(exc)) from exc


def format_duration(seconds: int) -> str:
    return format_duration_value(seconds)


def expand_path(value: str | os.PathLike[str]) -> pathlib.Path:
    return pathlib.Path(os.path.expandvars(os.path.expanduser(value))).resolve()


def default_state_dir() -> pathlib.Path:
    xdg_state = os.environ.get("XDG_STATE_HOME")
    if xdg_state:
        return expand_path(f"{xdg_state}/ssh-ticket")
    return expand_path("~/.local/state/ssh-ticket")


def state_dir_arg(args: argparse.Namespace) -> pathlib.Path:
    return expand_path(args.state_dir) if args.state_dir else default_state_dir()


def format_time(epoch: int) -> str:
    return dt.datetime.fromtimestamp(epoch).astimezone().strftime("%Y-%m-%d %H:%M:%S %Z")


def safe_name(value: str) -> str:
    safe = re.sub(r"[^A-Za-z0-9_.-]+", "_", value).strip("._-")
    return safe or "target"


def targets_file_arg(value: str | None) -> pathlib.Path | None:
    if value:
        return expand_path(value)
    env_targets_file = os.environ.get(TARGETS_FILE_ENV)
    if env_targets_file:
        return expand_path(env_targets_file)
    return None


def env_flag(name: str) -> bool | None:
    value = os.environ.get(name)
    if value is None:
        return None
    return value.strip().lower() in ("1", "true", "yes", "on")


def resolved_ca_key(args: argparse.Namespace) -> tuple[bool, pathlib.Path]:
    ca_agent = args.ca_agent
    if ca_agent is None:
        ca_agent = args.ca_key is None
    ca_key = args.ca_key or (DEFAULT_CA_PUBLIC_KEY if ca_agent else DEFAULT_CA_PRIVATE_KEY)
    return ca_agent, expand_path(ca_key)


def load_targets_from_file(targets_file: pathlib.Path) -> list[Target]:
    try:
        models = TARGETS.validate_json(targets_file.read_text(encoding="utf-8"))
    except OSError as exc:
        raise Error(f"failed to read targets file {targets_file}: {exc}") from exc
    except (DurationError, ValidationError) as exc:
        raise Error(f"failed to parse targets file {targets_file}: {exc}") from exc
    return sorted(models, key=lambda target: target.name)


def load_targets(targets_file: str | None = None) -> list[Target]:
    targets_path = targets_file_arg(targets_file)
    if targets_path is None:
        raise Error(f"target metadata requires --targets-file or ${TARGETS_FILE_ENV}")
    return load_targets_from_file(targets_path)


def resolve_target(
    targets: Sequence[Target], requested: str, *, allow_disabled: bool = False
) -> Target:
    exact = {target.name: target for target in targets}
    if requested in exact:
        target = exact[requested]
    else:
        matches = []
        for target in targets:
            if requested in target.aliases:
                matches.append(target)
        unique = {match.name: match for match in matches}
        if len(unique) > 1:
            names = ", ".join(sorted(unique))
            raise Error(f"ambiguous ticket target {requested!r}; matches: {names}")
        if not unique:
            known = ", ".join(target.name for target in targets if target.enabled)
            raise Error(
                f"unknown ticket target {requested!r}; enabled targets: {known or '<none>'}"
            )
        target = next(iter(unique.values()))

    if not target.enabled and not allow_disabled:
        raise Error(f"ticket target {target.name} exists but host.sshTicket.enable is false")
    return target


def target_paths(target_name: str, state_dir: pathlib.Path) -> TicketPaths:
    base = state_dir / safe_name(target_name)
    return TicketPaths(
        public=pathlib.Path(f"{base}.pub"),
        cert=pathlib.Path(f"{base}-cert.pub"),
        metadata=pathlib.Path(f"{base}.json"),
    )


@contextlib.contextmanager
def ticket_issue_lock(target_name: str, state_dir: pathlib.Path) -> Iterator[None]:
    state_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    lock_path = state_dir / f"{safe_name(target_name)}.lock"
    fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)


def ensure_ticket_key(key_path: pathlib.Path, runtime: Runtime) -> pathlib.Path:
    public_path = pathlib.Path(f"{key_path}.pub")
    key_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    if not key_path.exists():
        runtime.commands.run(
            [
                "ssh-keygen",
                "-q",
                "-t",
                "ed25519",
                "-N",
                "",
                "-C",
                "ssht ticket key",
                "-f",
                str(key_path),
            ],
            capture=False,
        )
    if not public_path.exists():
        public = runtime.commands.run(["ssh-keygen", "-y", "-f", str(key_path)])
        public_path.write_text(public, encoding="utf-8")
    key_path.chmod(0o600)
    return public_path


def read_metadata(path: pathlib.Path) -> TicketMetadata | None:
    try:
        return TicketMetadata.model_validate_json(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return None
    except ValidationError:
        return None


def write_metadata(path: pathlib.Path, value: TicketMetadata) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    write_text_atomic(
        path,
        value.model_dump_json(by_alias=True, indent=2) + "\n",
        mode=0o600,
    )


def existing_ticket_valid(target: Target, paths: TicketPaths, runtime: Runtime) -> bool:
    metadata = read_metadata(paths.metadata)
    if metadata is None or not paths.cert.exists():
        return False
    if metadata.target != target.name:
        return False
    if metadata.principal != target.principal:
        return False
    return metadata.valid_before - runtime.clock.now() > MIN_VALID_SECONDS


def ticket_status(target: Target, state_dir: pathlib.Path, runtime: Runtime) -> TicketStatus:
    paths = target_paths(target.name, state_dir)
    metadata = read_metadata(paths.metadata)
    if metadata is None or not paths.cert.exists():
        return TicketStatus(**target.model_dump(), status="missing")
    valid_before = metadata.valid_before
    if valid_before - runtime.clock.now() <= MIN_VALID_SECONDS:
        return TicketStatus(**target.model_dump(), status="expired", valid_before=valid_before)
    return TicketStatus(**target.model_dump(), status="valid", valid_before=valid_before)


def requested_ttl(args: argparse.Namespace, target: Target) -> int:
    ttl = parse_duration(args.ttl or target.default_ttl)
    max_ttl = parse_duration(target.max_ttl)
    if ttl > max_ttl:
        raise Error(
            f"requested TTL {format_duration(ttl)} exceeds max TTL "
            f"{format_duration(max_ttl)} for {target.name}"
        )
    return ttl


def issue_ticket(
    args: argparse.Namespace,
    target: Target,
    state_dir: pathlib.Path,
    key_path: pathlib.Path,
    runtime: Runtime,
) -> TicketPaths:
    ttl = requested_ttl(args, target)
    public_key = ensure_ticket_key(key_path, runtime)
    paths = target_paths(target.name, state_dir)
    state_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    public_text = public_key.read_text(encoding="utf-8")
    paths.public.write_text(public_text, encoding="utf-8")
    paths.cert.unlink(missing_ok=True)

    ca_agent, ca_key = resolved_ca_key(args)
    serial = runtime.clock.now()
    identity = f"ssht:{target.name}:{serial}"
    cmd = ["ssh-keygen", "-q"]
    if ca_agent:
        cmd.extend(["-U", "-s", str(ca_key)])
    else:
        cmd.extend(["-s", str(ca_key)])
    cmd.extend(
        [
            "-I",
            identity,
            "-n",
            target.principal,
            "-O",
            "no-agent-forwarding",
        ]
    )
    if target.allow_x11_forwarding:
        cmd.extend(["-O", "permit-X11-forwarding"])
    else:
        cmd.extend(["-O", "no-x11-forwarding"])
    cmd.extend(
        [
            "-V",
            f"-5m:+{ttl}s",
            "-z",
            str(serial),
            str(paths.public),
        ]
    )
    runtime.commands.run(cmd, capture=False)

    now = runtime.clock.now()
    metadata = TicketMetadata(
        target=target.name,
        ssh_host=target.ssh_host,
        principal=target.principal,
        identity=identity,
        valid_after=now - 300,
        valid_before=now + ttl,
        issued_at=now,
        ttl=ttl,
        allow_x11_forwarding=target.allow_x11_forwarding,
        certificate_file=str(paths.cert),
        identity_file=str(key_path),
        ca_agent=ca_agent,
        ca_key=str(ca_key),
    )
    write_metadata(paths.metadata, metadata)
    return paths


def ensure_ticket(args: argparse.Namespace, target: Target, runtime: Runtime) -> TicketPaths:
    state_dir = state_dir_arg(args)
    key_path = expand_path(args.key)
    paths = target_paths(target.name, state_dir)
    if not args.force and existing_ticket_valid(target, paths, runtime):
        return paths
    with ticket_issue_lock(target.name, state_dir):
        # Another process may have issued the ticket while this one waited.
        if not args.force and existing_ticket_valid(target, paths, runtime):
            return paths
        return issue_ticket(args, target, state_dir, key_path, runtime)


def write_ticket_alias(paths: TicketPaths, alias: str, state_dir: pathlib.Path) -> TicketPaths:
    alias_paths = target_paths(alias, state_dir)
    if alias_paths.cert == paths.cert:
        return alias_paths
    state_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    for source, destination in (
        (paths.public, alias_paths.public),
        (paths.cert, alias_paths.cert),
        (paths.metadata, alias_paths.metadata),
    ):
        if source.exists():
            destination.write_text(source.read_text(encoding="utf-8"), encoding="utf-8")
    return alias_paths


def cmd_targets(args: argparse.Namespace, _runtime: Runtime) -> int:
    targets = load_targets(args.targets_file)
    if not args.all:
        targets = [target for target in targets if target.enabled]
    if args.json:
        print(
            json.dumps(
                [target.model_dump(by_alias=True) for target in targets],
                indent=2,
                sort_keys=True,
            )
        )
        return 0
    if not targets:
        print("No ticket targets.")
        return 0
    rows = [
        (
            target.name,
            "yes" if target.enabled else "no",
            target.principal,
            ",".join(target.aliases),
            target.default_ttl,
            target.max_ttl,
            "yes" if target.ca_public_key_configured else "no",
        )
        for target in targets
    ]
    headers = ("target", "enabled", "principal", "aliases", "default", "max", "ca")
    widths = [len(header) for header in headers]
    for row in rows:
        widths = [max(width, len(value)) for width, value in zip(widths, row, strict=True)]
    print("  ".join(header.ljust(width) for header, width in zip(headers, widths, strict=True)))
    print("  ".join("-" * width for width in widths))
    for row in rows:
        print("  ".join(value.ljust(width) for value, width in zip(row, widths, strict=True)))
    return 0


def cmd_status(args: argparse.Namespace, runtime: Runtime) -> int:
    targets = load_targets(args.targets_file)
    state_dir = expand_path(args.state_dir) if args.state_dir else default_state_dir()
    if args.target:
        targets = [resolve_target(targets, args.target, allow_disabled=args.all)]
    elif not args.all:
        targets = [target for target in targets if target.enabled]
    statuses = [ticket_status(target, state_dir, runtime) for target in targets]
    if args.json:
        print(
            json.dumps(
                [status.model_dump(by_alias=True) for status in statuses],
                indent=2,
                sort_keys=True,
            )
        )
        return 0
    for status in statuses:
        if status.status == "valid" and status.valid_before is not None:
            detail = f"until {format_time(status.valid_before)}"
        elif status.status == "expired" and status.valid_before is not None:
            detail = f"expired {format_time(status.valid_before)}"
        else:
            detail = "missing"
        print(f"{status.name}: {status.status} ({detail})")
    return 0


def cmd_issue(args: argparse.Namespace, runtime: Runtime) -> int:
    targets = load_targets(args.targets_file)
    target = resolve_target(targets, args.target, allow_disabled=args.allow_disabled)
    state_dir = expand_path(args.state_dir) if args.state_dir else default_state_dir()
    paths = issue_ticket(args, target, state_dir, expand_path(args.key), runtime)
    print(str(paths.cert))
    return 0


def cmd_ensure(args: argparse.Namespace, runtime: Runtime) -> int:
    targets = load_targets(args.targets_file)
    target = resolve_target(targets, args.target, allow_disabled=args.allow_disabled)
    state_dir = state_dir_arg(args)
    paths = ensure_ticket(args, target, runtime)
    cert_alias = args.cert_alias or args.target
    alias_paths = write_ticket_alias(paths, cert_alias, state_dir)
    if not args.quiet:
        print(str(alias_paths.cert))
    return 0


def cmd_init_key(args: argparse.Namespace, runtime: Runtime) -> int:
    public_key = ensure_ticket_key(expand_path(args.key), runtime)
    print(str(public_key))
    return 0


def cmd_ssht(args: argparse.Namespace, runtime: Runtime) -> NoReturn:
    targets = load_targets(args.targets_file)
    target = resolve_target(targets, args.target, allow_disabled=args.allow_disabled)
    paths = ensure_ticket(args, target, runtime)
    cmd = ssht_ssh_command(args, target, paths)
    runtime.commands.exec(cmd)


def ssht_ssh_command(args: argparse.Namespace, target: Target, paths: TicketPaths) -> list[str]:
    ssh_args = list(args.ssh_args)
    if ssh_args and ssh_args[0] == "--":
        ssh_args = ssh_args[1:]
    return [
        "ssh",
        "-o",
        "IdentitiesOnly=yes",
        "-o",
        f"IdentityFile={expand_path(args.key)}",
        "-o",
        f"CertificateFile={paths.cert}",
        "-o",
        "ForwardAgent=no",
        "-o",
        "AddKeysToAgent=no",
        "-o",
        "ControlMaster=no",
        "-o",
        "ControlPath=none",
        target.ssh_host,
    ] + ssh_args


def add_target_source_options(parser: argparse.ArgumentParser) -> None:
    parser.add_argument(
        "--targets-file",
        help=f"JSON target metadata file; defaults to ${TARGETS_FILE_ENV} when set",
    )


def add_common_options(parser: argparse.ArgumentParser) -> None:
    add_target_source_options(parser)
    parser.add_argument("--state-dir", help="directory for per-host certificates and metadata")
    parser.add_argument(
        "--key",
        default=os.environ.get("SSHT_KEY", DEFAULT_KEY),
        help="ticket private key path",
    )
    parser.add_argument(
        "--ca-key",
        default=os.environ.get("SSHT_CA_KEY"),
        help="SSH user CA key path; defaults to ~/.ssh/fleet-user-ca.pub with agent signing",
    )
    ca_agent = parser.add_mutually_exclusive_group()
    ca_agent.add_argument(
        "--ca-agent",
        dest="ca_agent",
        action="store_true",
        help="sign with a CA key loaded in ssh-agent",
    )
    ca_agent.add_argument(
        "--no-ca-agent",
        dest="ca_agent",
        action="store_false",
        help="sign with a CA private key file",
    )
    parser.set_defaults(ca_agent=env_flag("SSHT_CA_AGENT"))
    parser.add_argument("--ttl", help="ticket lifetime, e.g. 30m, 2h, 1h30m")
    parser.add_argument("--force", action="store_true", help="ignore an existing valid ticket")
    parser.add_argument(
        "--allow-disabled",
        action="store_true",
        help="allow issuing for a target whose host.sshTicket.enable is false",
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="ssh-ticket")
    subparsers = parser.add_subparsers(dest="command", required=True)

    targets = subparsers.add_parser("targets", help="list configured SSH ticket targets")
    add_target_source_options(targets)
    targets.add_argument("--all", action="store_true", help="include disabled targets")
    targets.add_argument("--json", action="store_true", help="emit JSON")
    targets.set_defaults(func=cmd_targets)

    status = subparsers.add_parser("status", help="show local ticket status")
    status.add_argument("target", nargs="?", help="target or alias")
    add_target_source_options(status)
    status.add_argument("--state-dir", help="directory for per-host certificates and metadata")
    status.add_argument("--all", action="store_true", help="include disabled targets")
    status.add_argument("--json", action="store_true", help="emit JSON")
    status.set_defaults(func=cmd_status)

    issue = subparsers.add_parser("issue", help="issue a ticket for one host")
    add_common_options(issue)
    issue.add_argument("target", help="target or alias")
    issue.set_defaults(func=cmd_issue)

    ensure = subparsers.add_parser("ensure", help="issue or reuse a ticket without connecting")
    add_common_options(ensure)
    ensure.add_argument("target", help="target or alias")
    ensure.add_argument(
        "--cert-alias",
        help="also write the certificate to this state-dir alias for ssh_config",
    )
    ensure.add_argument("--quiet", action="store_true", help="do not print the cert path")
    ensure.set_defaults(func=cmd_ensure)

    init_key = subparsers.add_parser("init-key", help="create the reusable ticket keypair")
    init_key.add_argument(
        "--key",
        default=os.environ.get("SSHT_KEY", DEFAULT_KEY),
        help="ticket private key path",
    )
    init_key.set_defaults(func=cmd_init_key)

    ssht = subparsers.add_parser("ssht", help="connect to a host through a short-lived ticket")
    add_common_options(ssht)
    ssht.add_argument("target", help="target or alias")
    ssht.add_argument(
        "ssh_args",
        nargs=argparse.REMAINDER,
        help="arguments passed after the resolved ssh host",
    )
    ssht.set_defaults(func=cmd_ssht)
    return parser


def main(argv: Sequence[str], runtime: Runtime | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    runtime = runtime or system_runtime()
    try:
        return cast(int, args.func(args, runtime))
    except (CommandError, Error) as exc:
        print(f"ssh-ticket: {exc}", file=sys.stderr)
        return 1


def configure_darwin_ssh_agent() -> None:
    if sys.platform == "darwin":
        socket = os.environ.get("SSHT_SECRETIVE_SOCKET") or (
            pathlib.Path.home()
            / "Library/Containers/com.maxgoedjen.Secretive.SecretAgent/Data/socket.ssh"
        )
        os.environ["SSH_AUTH_SOCK"] = str(socket)


def cli() -> int:
    configure_darwin_ssh_agent()
    return main(sys.argv[1:])


def ssht_cli() -> int:
    configure_darwin_ssh_agent()
    return main(["ssht", *sys.argv[1:]])


if __name__ == "__main__":
    raise SystemExit(cli())
