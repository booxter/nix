#!/usr/bin/env python3

from __future__ import annotations

import argparse
import ipaddress
import json
import os
import subprocess
import time
from dataclasses import dataclass
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any


class ExporterError(RuntimeError):
    pass


@dataclass(frozen=True)
class PeerSpec:
    name: str
    public_key: str
    address: ipaddress.IPv4Address


@dataclass(frozen=True)
class PeerRuntime:
    public_key: str
    endpoint: str | None
    allowed_ips: tuple[str, ...]
    latest_handshake_seconds: int
    receive_bytes: int
    transmit_bytes: int
    persistent_keepalive_seconds: int | None


def load_peer_specs(raw_json: str) -> list[PeerSpec]:
    if not raw_json:
        raise ExporterError("missing peers JSON")

    try:
        decoded = json.loads(raw_json)
    except json.JSONDecodeError as error:
        raise ExporterError(f"invalid peers JSON: {error}") from error

    if not isinstance(decoded, list):
        raise ExporterError("peers JSON must be a list")

    peers: list[PeerSpec] = []
    seen_names: set[str] = set()
    seen_keys: set[str] = set()
    for index, item in enumerate(decoded):
        if not isinstance(item, dict):
            raise ExporterError(f"peer item {index} is not an object")

        name = item.get("name")
        public_key = item.get("publicKey", item.get("public_key"))
        address = item.get("address")
        if not isinstance(name, str) or not name.strip():
            raise ExporterError(f"peer item {index} is missing name")
        if not isinstance(public_key, str) or not public_key.strip():
            raise ExporterError(f"peer item {index} is missing publicKey")
        if not isinstance(address, str):
            raise ExporterError(f"peer item {index} is missing address")

        parsed_address = ipaddress.ip_interface(address)
        if not isinstance(parsed_address.ip, ipaddress.IPv4Address):
            raise ExporterError(f"peer item {index} address is not IPv4: {address}")

        normalized_name = name.strip()
        normalized_key = public_key.strip()
        if normalized_name in seen_names:
            raise ExporterError(f"duplicate peer name: {normalized_name}")
        if normalized_key in seen_keys:
            raise ExporterError(f"duplicate peer public key for {normalized_name}")
        seen_names.add(normalized_name)
        seen_keys.add(normalized_key)
        peers.append(
            PeerSpec(
                name=normalized_name,
                public_key=normalized_key,
                address=parsed_address.ip,
            )
        )

    return peers


def parse_optional_int(value: str) -> int | None:
    if value == "off":
        return None
    return int(value)


def parse_wg_dump(output: str) -> dict[str, PeerRuntime]:
    peers: dict[str, PeerRuntime] = {}
    for line_number, line in enumerate(output.splitlines(), start=1):
        fields = line.split("\t")
        if not fields or len(fields) < 5:
            continue

        if line_number == 1:
            # Interface row: private-key, public-key, listen-port, fwmark.
            continue

        if len(fields) < 8:
            raise ExporterError(
                f"unexpected wg dump peer row {line_number}: expected at least 8 fields"
            )

        public_key = fields[0]
        endpoint = None if fields[2] == "(none)" else fields[2]
        allowed_ips = tuple(
            item for item in fields[3].split(",") if item and item != "(none)"
        )
        peers[public_key] = PeerRuntime(
            public_key=public_key,
            endpoint=endpoint,
            allowed_ips=allowed_ips,
            latest_handshake_seconds=int(fields[4]),
            receive_bytes=int(fields[5]),
            transmit_bytes=int(fields[6]),
            persistent_keepalive_seconds=parse_optional_int(fields[7]),
        )

    return peers


def collect_wg_dump(interface: str, wg_command: str) -> dict[str, PeerRuntime]:
    completed = subprocess.run(
        [wg_command, "show", interface, "dump"],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if completed.returncode != 0:
        raise ExporterError(
            f"wg show {interface} dump failed: {completed.stderr.strip()}"
        )
    return parse_wg_dump(completed.stdout)


def peer_status(
    peer: PeerSpec,
    runtime: PeerRuntime | None,
    interface: str,
    now: int,
    handshake_max_age_seconds: int,
) -> dict[str, Any]:
    latest_handshake = runtime.latest_handshake_seconds if runtime is not None else 0
    latest_handshake_age = None
    if latest_handshake > 0:
        latest_handshake_age = max(0, now - latest_handshake)
    connected = (
        latest_handshake_age is not None
        and latest_handshake_age <= handshake_max_age_seconds
    )

    return {
        "interface": interface,
        "name": peer.name,
        "public_key": peer.public_key,
        "address": str(peer.address),
        "endpoint": runtime.endpoint if runtime is not None else None,
        "allowed_ips": list(runtime.allowed_ips) if runtime is not None else [],
        "latest_handshake_seconds": latest_handshake,
        "latest_handshake_age_seconds": latest_handshake_age,
        "connected": connected,
        "receive_bytes": runtime.receive_bytes if runtime is not None else 0,
        "transmit_bytes": runtime.transmit_bytes if runtime is not None else 0,
        "persistent_keepalive_seconds": (
            runtime.persistent_keepalive_seconds if runtime is not None else None
        ),
    }


def build_status_document(
    peers: list[PeerSpec],
    interface: str,
    wg_command: str,
    handshake_max_age_seconds: int,
) -> dict[str, Any]:
    now = int(time.time())
    runtimes = collect_wg_dump(interface=interface, wg_command=wg_command)
    statuses = [
        peer_status(
            peer=peer,
            runtime=runtimes.get(peer.public_key),
            interface=interface,
            now=now,
            handshake_max_age_seconds=handshake_max_age_seconds,
        )
        for peer in peers
    ]
    return {
        "interface": interface,
        "now": now,
        "handshake_max_age_seconds": handshake_max_age_seconds,
        "peers": statuses,
    }


def prometheus_escape_label(value: str) -> str:
    return value.replace("\\", "\\\\").replace("\n", "\\n").replace('"', '\\"')


def metric_labels(peer: dict[str, Any]) -> str:
    labels = {
        "interface": str(peer["interface"]),
        "peer": str(peer["name"]),
        "address": str(peer["address"]),
        "public_key": str(peer["public_key"]),
    }
    return ",".join(
        f'{key}="{prometheus_escape_label(value)}"' for key, value in labels.items()
    )


def render_metrics(status: dict[str, Any]) -> str:
    lines = [
        "# HELP wg_home_peer_info Inventory-backed WireGuard peer metadata.",
        "# TYPE wg_home_peer_info gauge",
        "# HELP wg_home_peer_connected Whether a WireGuard peer has a recent handshake.",
        "# TYPE wg_home_peer_connected gauge",
        "# HELP wg_home_peer_latest_handshake_seconds Unix timestamp of the latest WireGuard peer handshake.",
        "# TYPE wg_home_peer_latest_handshake_seconds gauge",
        "# HELP wg_home_peer_latest_handshake_age_seconds Age of the latest WireGuard peer handshake.",
        "# TYPE wg_home_peer_latest_handshake_age_seconds gauge",
        "# HELP wg_home_peer_receive_bytes_total WireGuard peer receive bytes.",
        "# TYPE wg_home_peer_receive_bytes_total counter",
        "# HELP wg_home_peer_transmit_bytes_total WireGuard peer transmit bytes.",
        "# TYPE wg_home_peer_transmit_bytes_total counter",
    ]

    for peer in status["peers"]:
        labels = metric_labels(peer)
        lines.append(f"wg_home_peer_info{{{labels}}} 1")
        lines.append(
            f"wg_home_peer_connected{{{labels}}} {1 if peer['connected'] else 0}"
        )
        lines.append(
            f"wg_home_peer_latest_handshake_seconds{{{labels}}} {peer['latest_handshake_seconds']}"
        )
        if peer["latest_handshake_age_seconds"] is not None:
            lines.append(
                f"wg_home_peer_latest_handshake_age_seconds{{{labels}}} {peer['latest_handshake_age_seconds']}"
            )
        lines.append(
            f"wg_home_peer_receive_bytes_total{{{labels}}} {peer['receive_bytes']}"
        )
        lines.append(
            f"wg_home_peer_transmit_bytes_total{{{labels}}} {peer['transmit_bytes']}"
        )

    return "\n".join(lines) + "\n"


class Handler(BaseHTTPRequestHandler):
    peers: list[PeerSpec] = []
    interface: str = "wg0"
    wg_command: str = "wg"
    handshake_max_age_seconds: int = 180

    def log_message(self, format: str, *args: object) -> None:
        return

    def send_text(self, status: HTTPStatus, body: str, content_type: str) -> None:
        encoded = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", f"{content_type}; charset=utf-8")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def do_GET(self) -> None:
        try:
            status = build_status_document(
                peers=self.peers,
                interface=self.interface,
                wg_command=self.wg_command,
                handshake_max_age_seconds=self.handshake_max_age_seconds,
            )
        except ExporterError as error:
            self.send_text(HTTPStatus.INTERNAL_SERVER_ERROR, f"{error}\n", "text/plain")
            return

        if self.path == "/metrics":
            self.send_text(HTTPStatus.OK, render_metrics(status), "text/plain")
            return

        if self.path == "/peers.json":
            self.send_text(
                HTTPStatus.OK,
                json.dumps(status, indent=2, sort_keys=True) + "\n",
                "application/json",
            )
            return

        self.send_text(HTTPStatus.NOT_FOUND, "not found\n", "text/plain")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="wg-home-exporter",
        description="Expose inventory-backed WireGuard peer connection state.",
    )
    parser.add_argument("--interface", default=os.environ.get("WG_INTERFACE", "wg0"))
    parser.add_argument(
        "--listen-address",
        default=os.environ.get("WG_HOME_EXPORTER_LISTEN_ADDRESS", "127.0.0.1"),
    )
    parser.add_argument(
        "--port",
        type=int,
        default=int(os.environ.get("WG_HOME_EXPORTER_PORT", "9586")),
    )
    parser.add_argument(
        "--handshake-max-age-seconds",
        type=int,
        default=int(os.environ.get("WG_HOME_HANDSHAKE_MAX_AGE_SECONDS", "180")),
    )
    parser.add_argument(
        "--peers-json",
        default=os.environ.get("WG_HOME_PEERS_JSON", ""),
        help="JSON array of peers with name, publicKey, and address.",
    )
    parser.add_argument(
        "--peers-json-file",
        default=os.environ.get("WG_HOME_PEERS_JSON_FILE", ""),
        help="Path to a JSON array of peers with name, publicKey, and address.",
    )
    parser.add_argument(
        "--wg-command",
        default=os.environ.get("WG_COMMAND", "wg"),
        help="Path to the wg command.",
    )
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()

    if args.handshake_max_age_seconds < 1:
        print("error: --handshake-max-age-seconds must be positive", flush=True)
        return 1

    raw_peers_json = args.peers_json
    if args.peers_json_file:
        with open(args.peers_json_file, encoding="utf-8") as handle:
            raw_peers_json = handle.read()

    try:
        peers = load_peer_specs(raw_peers_json)
    except ExporterError as error:
        print(f"error: {error}", flush=True)
        return 1

    Handler.peers = peers
    Handler.interface = args.interface
    Handler.wg_command = args.wg_command
    Handler.handshake_max_age_seconds = args.handshake_max_age_seconds

    server = ThreadingHTTPServer((args.listen_address, args.port), Handler)
    print(
        f"listening on {args.listen_address}:{args.port} for {args.interface}",
        flush=True,
    )
    server.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
