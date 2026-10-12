from __future__ import annotations

import os
import socket
import sys
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from ipaddress import IPv4Address
from pathlib import Path
from typing import NoReturn, Protocol

import psutil


@dataclass(frozen=True)
class Configuration:
    client: Path
    interface: str
    portal_file: Path
    port: int

    @classmethod
    def from_environment(cls, environment: Mapping[str, str]) -> Configuration:
        port = int(environment["GPCONNECT_PORT"])
        if not 1 <= port <= 65535:
            raise ValueError("authentication port must be between 1 and 65535")

        return cls(
            client=Path(environment["GPCONNECT_CLIENT"]),
            interface=environment["GPCONNECT_INTERFACE"],
            portal_file=Path(environment["GPCONNECT_PORTAL_FILE"]),
            port=port,
        )


@dataclass(frozen=True)
class Connection:
    configuration: Configuration
    portal: str
    address: IPv4Address
    arguments: tuple[str, ...]


class Runtime(Protocol):
    def read_portal(self, path: Path) -> str: ...

    def ipv4_addresses(self, interface: str) -> Sequence[IPv4Address]: ...

    def launch(self, connection: Connection) -> NoReturn: ...


class LocalRuntime:
    def read_portal(self, path: Path) -> str:
        return path.read_text().strip()

    def ipv4_addresses(self, interface: str) -> Sequence[IPv4Address]:
        return [
            IPv4Address(address.address)
            for address in psutil.net_if_addrs().get(interface, [])
            if address.family == socket.AF_INET
        ]

    def launch(self, connection: Connection) -> NoReturn:
        configuration = connection.configuration
        # Replace the wrapper so gpclient owns the terminal, signals, and exit status.
        os.execv(
            configuration.client,
            [
                str(configuration.client),
                "connect",
                connection.portal,
                "--browser",
                "remote",
                "--browser-listen",
                f"{connection.address}:{configuration.port}",
                *connection.arguments,
            ],
        )


def connect(configuration: Configuration, arguments: Sequence[str], runtime: Runtime) -> NoReturn:
    portal = runtime.read_portal(configuration.portal_file)
    if not portal:
        raise ValueError(f"portal secret is empty: {configuration.portal_file}")

    addresses = runtime.ipv4_addresses(configuration.interface)
    if len(addresses) != 1:
        raise ValueError(
            f"expected one IPv4 address on {configuration.interface}, found {len(addresses)}"
        )

    runtime.launch(Connection(configuration, portal, addresses[0], tuple(arguments)))


def main(
    argv: Sequence[str] | None = None,
    *,
    environment: Mapping[str, str] | None = None,
    runtime: Runtime | None = None,
) -> int:
    try:
        configuration = Configuration.from_environment(
            os.environ if environment is None else environment
        )
        connect(
            configuration,
            sys.argv[1:] if argv is None else argv,
            LocalRuntime() if runtime is None else runtime,
        )
    except (KeyError, OSError, ValueError) as error:
        print(f"gpconnect: {error}", file=sys.stderr)
        return 1
