#!/usr/bin/env python3

from __future__ import annotations

import argparse
import ipaddress
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request
from dataclasses import dataclass
from typing import Any


class SyncError(RuntimeError):
    pass


@dataclass(frozen=True)
class PeerDnsSpec:
    name: str
    domain: str
    address: ipaddress.IPv4Address


def normalize_dns_name(value: str) -> str:
    normalized = value.strip().rstrip(".").lower()
    if not normalized:
        raise SyncError("DNS name must not be empty")

    labels = normalized.split(".")
    for label in labels:
        if not label:
            raise SyncError(f"DNS name has an empty label: {value}")
        if len(label.encode("idna")) > 63:
            raise SyncError(f"DNS label is too long in {value}")

    encoded_length = sum(len(label.encode("idna")) + 1 for label in labels) + 1
    if encoded_length > 255:
        raise SyncError(f"DNS name is too long: {value}")

    return normalized


def load_peer_dns_specs(raw_json: str) -> list[PeerDnsSpec]:
    if not raw_json:
        raise SyncError("missing peer DNS JSON")

    try:
        decoded = json.loads(raw_json)
    except json.JSONDecodeError as error:
        raise SyncError(f"invalid peer DNS JSON: {error}") from error

    if not isinstance(decoded, list):
        raise SyncError("peer DNS JSON must be a list")

    peers: list[PeerDnsSpec] = []
    seen_names: set[str] = set()
    seen_domains: set[str] = set()
    for index, item in enumerate(decoded):
        if not isinstance(item, dict):
            raise SyncError(f"peer DNS item {index} is not an object")

        name = item.get("name")
        domain = item.get("domain")
        address = item.get("address")
        if not isinstance(name, str) or not name.strip():
            raise SyncError(f"peer DNS item {index} is missing name")
        if not isinstance(domain, str):
            raise SyncError(f"peer DNS item {index} is missing domain")
        if not isinstance(address, str):
            raise SyncError(f"peer DNS item {index} is missing address")

        parsed_address = ipaddress.ip_address(address)
        if not isinstance(parsed_address, ipaddress.IPv4Address):
            raise SyncError(f"peer DNS item {index} address is not IPv4: {address}")

        normalized_name = name.strip()
        normalized_domain = normalize_dns_name(domain)
        if normalized_name in seen_names:
            raise SyncError(f"duplicate peer DNS name: {normalized_name}")
        if normalized_domain in seen_domains:
            raise SyncError(f"duplicate peer DNS domain: {normalized_domain}")
        seen_names.add(normalized_name)
        seen_domains.add(normalized_domain)

        peers.append(
            PeerDnsSpec(
                name=normalized_name,
                domain=normalized_domain,
                address=parsed_address,
            )
        )

    return peers


def fetch_status(url: str, timeout_seconds: float) -> dict[str, Any]:
    try:
        with urllib.request.urlopen(url, timeout=timeout_seconds) as response:
            payload = response.read().decode("utf-8")
    except (urllib.error.URLError, TimeoutError) as error:
        raise SyncError(
            f"failed to fetch WireGuard status from {url}: {error}"
        ) from error

    try:
        decoded = json.loads(payload)
    except json.JSONDecodeError as error:
        raise SyncError(f"WireGuard status from {url} is not JSON: {error}") from error

    if not isinstance(decoded, dict):
        raise SyncError(f"WireGuard status from {url} must be an object")
    peers = decoded.get("peers")
    if not isinstance(peers, list):
        raise SyncError(f"WireGuard status from {url} must contain peers list")
    return decoded


def build_status_by_name(status: dict[str, Any]) -> dict[str, dict[str, Any]]:
    by_name: dict[str, dict[str, Any]] = {}
    for index, item in enumerate(status["peers"]):
        if not isinstance(item, dict):
            raise SyncError(f"WireGuard status peer {index} is not an object")
        name = item.get("name")
        if not isinstance(name, str) or not name:
            raise SyncError(f"WireGuard status peer {index} is missing name")
        if name in by_name:
            raise SyncError(f"WireGuard status has duplicate peer name: {name}")
        by_name[name] = item
    return by_name


def build_dns_records(
    peer_specs: list[PeerDnsSpec],
    status_by_name: dict[str, dict[str, Any]],
    ttl_seconds: int,
) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    for peer in peer_specs:
        status = status_by_name.get(peer.name)
        if status is None:
            raise SyncError(f"WireGuard status is missing peer: {peer.name}")

        status_address = status.get("address")
        if isinstance(status_address, str) and status_address != str(peer.address):
            raise SyncError(
                f"WireGuard status address for {peer.name} is {status_address}, expected {peer.address}"
            )

        connected = status.get("connected")
        if not isinstance(connected, bool):
            raise SyncError(
                f"WireGuard status connected for {peer.name} is not boolean"
            )

        records.append(
            {
                "type": "A_RECORD",
                "domain": peer.domain,
                "ttlSeconds": ttl_seconds,
                "ipv4Address": str(peer.address),
                "enabled": connected,
            }
        )

    return records


def format_json(data: Any) -> str:
    return json.dumps(data, indent=2, sort_keys=True)


def run_unifi_sync(
    unifi_sync_command: str,
    dns_records: list[dict[str, Any]],
    dry_run: bool,
) -> subprocess.CompletedProcess[str]:
    command = [
        unifi_sync_command,
        "--no-reservations-update",
        "--no-dhcp-range-update",
        "--no-static-routes-update",
    ]
    if dry_run:
        command.append("--dry-run")

    env = os.environ.copy()
    env["UNIFI_DNS_RECORDS_JSON"] = json.dumps(dns_records, sort_keys=True)
    return subprocess.run(
        command,
        check=False,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="wg-home-dns-sync",
        description="Sync WireGuard peer DNS overrides through unifi-sync.",
    )
    parser.add_argument(
        "--status-url",
        default=os.environ.get("WG_HOME_STATUS_URL", ""),
        help="WireGuard exporter JSON URL, usually http://gateway:9586/peers.json.",
    )
    parser.add_argument(
        "--timeout-seconds",
        type=float,
        default=float(os.environ.get("WG_HOME_STATUS_TIMEOUT_SECONDS", "10")),
    )
    parser.add_argument(
        "--ttl-seconds",
        type=int,
        default=int(os.environ.get("WG_HOME_DNS_TTL_SECONDS", "60")),
    )
    parser.add_argument(
        "--peers-json",
        default=os.environ.get("WG_HOME_DNS_PEERS_JSON", ""),
        help="JSON array of peers with name, domain, and address.",
    )
    parser.add_argument(
        "--peers-json-file",
        default=os.environ.get("WG_HOME_DNS_PEERS_JSON_FILE", ""),
        help="Path to a JSON array of peers with name, domain, and address.",
    )
    parser.add_argument(
        "--output-records",
        default="",
        help="Optional path to write the generated DNS records JSON.",
    )
    parser.add_argument(
        "--unifi-sync-command",
        default=os.environ.get("UNIFI_SYNC_COMMAND", ""),
        help="Optional unifi-sync executable to apply generated DNS records.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Pass --dry-run to unifi-sync when applying records.",
    )
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()

    if not args.status_url:
        print("error: missing --status-url", file=sys.stderr)
        return 1
    if args.timeout_seconds <= 0:
        print("error: --timeout-seconds must be positive", file=sys.stderr)
        return 1
    if args.ttl_seconds < 0:
        print("error: --ttl-seconds must be non-negative", file=sys.stderr)
        return 1

    raw_peers_json = args.peers_json
    if args.peers_json_file:
        with open(args.peers_json_file, encoding="utf-8") as handle:
            raw_peers_json = handle.read()

    try:
        peer_specs = load_peer_dns_specs(raw_peers_json)
        status = fetch_status(args.status_url, timeout_seconds=args.timeout_seconds)
        dns_records = build_dns_records(
            peer_specs=peer_specs,
            status_by_name=build_status_by_name(status),
            ttl_seconds=args.ttl_seconds,
        )
    except SyncError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    summary: dict[str, Any] = {
        "status_url": args.status_url,
        "dry_run": args.dry_run,
        "dns_records": dns_records,
    }

    if args.output_records:
        with open(args.output_records, "w", encoding="utf-8") as handle:
            handle.write(json.dumps(dns_records, indent=2, sort_keys=True) + "\n")
        summary["output_records"] = args.output_records

    if args.unifi_sync_command:
        completed = run_unifi_sync(
            unifi_sync_command=args.unifi_sync_command,
            dns_records=dns_records,
            dry_run=args.dry_run,
        )
        summary["unifi_sync"] = {
            "returncode": completed.returncode,
            "stdout": completed.stdout,
            "stderr": completed.stderr,
        }
        print(format_json(summary))
        if completed.returncode != 0:
            return completed.returncode
        return 0

    print(format_json(summary))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
