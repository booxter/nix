from __future__ import annotations

import json
import os
import subprocess
import sys
from collections.abc import Mapping, Sequence
from dataclasses import dataclass, field
from ipaddress import IPv4Address
from pathlib import Path
from typing import NoReturn

import pytest
from gpconnect.cli import Connection, LocalRuntime, main


class ClientStarted(Exception):
    def __init__(self, connection: Connection) -> None:
        super().__init__("client started")
        self.connection = connection


@dataclass
class FakeRuntime:
    addresses: Mapping[str, Sequence[IPv4Address]] = field(
        default_factory=lambda: {"ens18": (IPv4Address("192.168.10.138"),)}
    )
    launch_error: OSError | None = None

    def read_portal(self, path: Path) -> str:
        return path.read_text().strip()

    def ipv4_addresses(self, interface: str) -> Sequence[IPv4Address]:
        return self.addresses.get(interface, ())

    def launch(self, connection: Connection) -> NoReturn:
        if self.launch_error is not None:
            raise self.launch_error
        raise ClientStarted(connection)


@pytest.fixture
def environment(tmp_path: Path) -> dict[str, str]:
    portal = tmp_path / "portal"
    portal.write_text("https://vpn.example.com\n")
    return {
        "GPCONNECT_CLIENT": "/nix/store/test-gpclient/bin/gpclient",
        "GPCONNECT_INTERFACE": "ens18",
        "GPCONNECT_PORTAL_FILE": str(portal),
        "GPCONNECT_PORT": "38080",
    }


@pytest.mark.parametrize("address", ["192.168.10.138", "192.168.10.139"])
def test_uses_current_interface_address_and_forwards_options(
    environment: dict[str, str], address: str
) -> None:
    runtime = FakeRuntime(addresses={"ens18": (IPv4Address(address),)})
    with pytest.raises(ClientStarted) as started:
        main(["--hip", "--gateway", "work"], environment=environment, runtime=runtime)

    connection = started.value.connection
    assert connection.portal == "https://vpn.example.com"
    assert connection.address == IPv4Address(address)
    assert connection.configuration.port == 38080
    assert connection.arguments == ("--hip", "--gateway", "work")


@pytest.mark.parametrize("contents", ["", " \n"])
def test_empty_portal_fails_before_connecting(
    environment: dict[str, str], contents: str, capsys: pytest.CaptureFixture[str]
) -> None:
    Path(environment["GPCONNECT_PORTAL_FILE"]).write_text(contents)
    assert main([], environment=environment, runtime=FakeRuntime()) == 1
    assert "portal secret is empty" in capsys.readouterr().err


def test_missing_portal_reports_its_path(
    environment: dict[str, str], capsys: pytest.CaptureFixture[str]
) -> None:
    Path(environment["GPCONNECT_PORTAL_FILE"]).unlink()
    assert main([], environment=environment, runtime=FakeRuntime()) == 1
    assert environment["GPCONNECT_PORTAL_FILE"] in capsys.readouterr().err


@pytest.mark.parametrize("addresses", [(), ("192.168.10.138", "192.168.10.139")])
def test_missing_or_ambiguous_interface_address_fails(
    environment: dict[str, str],
    addresses: tuple[str, ...],
    capsys: pytest.CaptureFixture[str],
) -> None:
    runtime = FakeRuntime(addresses={"ens18": tuple(IPv4Address(value) for value in addresses)})
    assert main([], environment=environment, runtime=runtime) == 1
    assert f"expected one IPv4 address on ens18, found {len(addresses)}" in capsys.readouterr().err


@pytest.mark.parametrize("port", ["0", "65536", "invalid"])
def test_invalid_port_fails(environment: dict[str, str], port: str) -> None:
    environment["GPCONNECT_PORT"] = port
    assert main([], environment=environment, runtime=FakeRuntime()) == 1


def test_missing_configuration_fails(environment: dict[str, str]) -> None:
    del environment["GPCONNECT_INTERFACE"]
    assert main([], environment=environment, runtime=FakeRuntime()) == 1


def test_client_launch_failure_is_reported(
    environment: dict[str, str], capsys: pytest.CaptureFixture[str]
) -> None:
    runtime = FakeRuntime(launch_error=OSError("client unavailable"))
    assert main([], environment=environment, runtime=runtime) == 1
    assert "gpconnect: client unavailable" in capsys.readouterr().err


def test_reads_native_interface_addresses() -> None:
    runtime = LocalRuntime()
    assert IPv4Address("127.0.0.1") in runtime.ipv4_addresses("lo")
    assert runtime.ipv4_addresses("no-such-interface") == []


def test_real_command_hands_terminal_and_exit_status_to_client(
    environment: dict[str, str], tmp_path: Path
) -> None:
    client = tmp_path / "gpclient"
    client.write_text(
        f"#!{sys.executable}\n"
        "import argparse, json\n"
        "parser = argparse.ArgumentParser()\n"
        "parser.add_argument('command')\n"
        "parser.add_argument('portal')\n"
        "parser.add_argument('--browser')\n"
        "parser.add_argument('--browser-listen')\n"
        "parser.add_argument('--user')\n"
        "print(json.dumps(vars(parser.parse_args())))\n"
        "raise SystemExit(23)\n"
    )
    client.chmod(0o755)
    environment["GPCONNECT_CLIENT"] = str(client)
    environment["GPCONNECT_INTERFACE"] = "lo"
    result = subprocess.run(
        [
            sys.executable,
            "-c",
            "from gpconnect.cli import main; raise SystemExit(main())",
            "--user",
            "operator",
        ],
        env=os.environ | environment,
        text=True,
        capture_output=True,
        check=False,
    )

    assert result.returncode == 23, result.stderr
    session = json.loads(result.stdout)
    assert session["command"] == "connect"
    assert session["portal"] == "https://vpn.example.com"
    assert session["browser"] == "remote"
    assert session["browser_listen"] == "127.0.0.1:38080"
    assert session["user"] == "operator"
