from __future__ import annotations

import argparse
import os
import secrets
from collections.abc import Mapping, Sequence


def forwarding_environment(
    values: Mapping[str, str], *, local_socket: str | None, connection_id: str
) -> dict[str, str]:
    environment = dict(values)
    environment.pop("SOPS_SSH_SOURCE_SOCKET", None)
    environment.pop("SOPS_SSH_CONNECTION", None)

    source: str | None
    service = values.get("SOPS_KEYSERVICE", "")
    if service.startswith("unix:///"):
        source = service.removeprefix("unix://")
    elif values.get("SSH_CONNECTION") or service:
        # An onward connection must not silently switch to this host's key.
        return environment
    else:
        source = local_socket

    if source:
        environment["SOPS_SSH_SOURCE_SOCKET"] = source
        environment["SOPS_SSH_CONNECTION"] = connection_id
    return environment


def main(argv: Sequence[str] | None = None) -> None:
    parser = argparse.ArgumentParser(
        description="Forward the originating SOPS key service over SSH."
    )
    parser.add_argument("--ssh", required=True)
    parser.add_argument("--forwarding-config", required=True)
    parser.add_argument("--local-socket")
    parser.add_argument("arguments", nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    arguments = args.arguments
    if arguments[:1] == ["--"]:
        arguments = arguments[1:]

    environment = forwarding_environment(
        os.environ, local_socket=args.local_socket, connection_id=secrets.token_hex(12)
    )
    if "SOPS_SSH_SOURCE_SOCKET" in environment:
        # A later user-supplied -F overrides this, as with ordinary OpenSSH.
        arguments = ["-F", args.forwarding_config, *arguments]

    os.execve(args.ssh, [args.ssh, *arguments], environment)
