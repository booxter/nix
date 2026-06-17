#!/usr/bin/env python3

from __future__ import annotations

import argparse
import ipaddress
import json
import os
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from typing import Any


class SyncError(RuntimeError):
    pass


@dataclass(frozen=True)
class PeerDnsSpec:
    name: str
    public_key: str
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
    seen_public_keys: set[str] = set()
    seen_domains: set[str] = set()
    for index, item in enumerate(decoded):
        if not isinstance(item, dict):
            raise SyncError(f"peer DNS item {index} is not an object")

        name = item.get("name")
        public_key = item.get("publicKey", item.get("public_key"))
        domain = item.get("domain")
        address = item.get("address")
        if not isinstance(name, str) or not name.strip():
            raise SyncError(f"peer DNS item {index} is missing name")
        if not isinstance(public_key, str) or not public_key.strip():
            raise SyncError(f"peer DNS item {index} is missing publicKey")
        if not isinstance(domain, str):
            raise SyncError(f"peer DNS item {index} is missing domain")
        if not isinstance(address, str):
            raise SyncError(f"peer DNS item {index} is missing address")

        parsed_address = ipaddress.ip_address(address)
        if not isinstance(parsed_address, ipaddress.IPv4Address):
            raise SyncError(f"peer DNS item {index} address is not IPv4: {address}")

        normalized_name = name.strip()
        normalized_public_key = public_key.strip()
        normalized_domain = normalize_dns_name(domain)
        if normalized_name in seen_names:
            raise SyncError(f"duplicate peer DNS name: {normalized_name}")
        if normalized_public_key in seen_public_keys:
            raise SyncError(f"duplicate peer DNS publicKey for {normalized_name}")
        if normalized_domain in seen_domains:
            raise SyncError(f"duplicate peer DNS domain: {normalized_domain}")
        seen_names.add(normalized_name)
        seen_public_keys.add(normalized_public_key)
        seen_domains.add(normalized_domain)

        peers.append(
            PeerDnsSpec(
                name=normalized_name,
                public_key=normalized_public_key,
                domain=normalized_domain,
                address=parsed_address,
            )
        )

    return peers


def build_https_context(
    url: str,
    ca_file: str,
    client_cert_file: str,
    client_key_file: str,
) -> ssl.SSLContext | None:
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme != "https":
        return None

    missing = [
        name
        for name, value in (
            ("--ca-file", ca_file),
            ("--client-cert-file", client_cert_file),
            ("--client-key-file", client_key_file),
        )
        if not value
    ]
    if missing:
        raise SyncError(f"HTTPS WireGuard status URL requires {', '.join(missing)}")

    context = ssl.create_default_context(cafile=ca_file)
    context.load_cert_chain(certfile=client_cert_file, keyfile=client_key_file)
    return context


def fetch_metrics(
    url: str,
    timeout_seconds: float,
    ca_file: str,
    client_cert_file: str,
    client_key_file: str,
) -> str:
    context = build_https_context(
        url=url,
        ca_file=ca_file,
        client_cert_file=client_cert_file,
        client_key_file=client_key_file,
    )
    try:
        with urllib.request.urlopen(
            url,
            timeout=timeout_seconds,
            context=context,
        ) as response:
            return response.read().decode("utf-8")
    except (urllib.error.URLError, TimeoutError) as error:
        raise SyncError(
            f"failed to fetch WireGuard metrics from {url}: {error}"
        ) from error


def split_prometheus_sample(line: str) -> tuple[str, str]:
    in_labels = False
    in_quotes = False
    escaped = False
    for index, char in enumerate(line):
        if in_quotes:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                in_quotes = False
            continue

        if char == '"':
            in_quotes = True
        elif char == "{":
            in_labels = True
        elif char == "}":
            in_labels = False
        elif char.isspace() and not in_labels:
            sample = line[:index]
            value = line[index:].strip()
            if not sample or not value:
                raise SyncError(f"invalid Prometheus metric line: {line}")
            return sample, value

    raise SyncError(f"Prometheus metric line is missing value: {line}")


def decode_prometheus_label_value(raw_value: str, start: int) -> tuple[str, int]:
    index = start
    value: list[str] = []
    while index < len(raw_value):
        char = raw_value[index]
        index += 1
        if char == "\\":
            if index >= len(raw_value):
                raise SyncError("Prometheus label value ends with escape")
            escaped = raw_value[index]
            index += 1
            if escaped == "n":
                value.append("\n")
            elif escaped in ('"', "\\"):
                value.append(escaped)
            else:
                value.append(escaped)
        elif char == '"':
            return "".join(value), index
        else:
            value.append(char)

    raise SyncError("Prometheus label value is missing closing quote")


def parse_prometheus_labels(raw_labels: str) -> dict[str, str]:
    labels: dict[str, str] = {}
    index = 0
    while index < len(raw_labels):
        while index < len(raw_labels) and raw_labels[index].isspace():
            index += 1
        if index >= len(raw_labels):
            break

        equals_index = raw_labels.find("=", index)
        if equals_index < 0:
            raise SyncError(f"Prometheus label is missing '=': {raw_labels}")

        name = raw_labels[index:equals_index].strip()
        if not name:
            raise SyncError(f"Prometheus label is missing name: {raw_labels}")

        index = equals_index + 1
        if index >= len(raw_labels) or raw_labels[index] != '"':
            raise SyncError(f"Prometheus label {name} is missing quoted value")

        value, index = decode_prometheus_label_value(raw_labels, index + 1)
        if name in labels:
            raise SyncError(f"duplicate Prometheus label: {name}")
        labels[name] = value

        while index < len(raw_labels) and raw_labels[index].isspace():
            index += 1
        if index >= len(raw_labels):
            break
        if raw_labels[index] != ",":
            raise SyncError(f"Prometheus labels are not comma separated: {raw_labels}")
        index += 1

    return labels


def parse_prometheus_metric_line(line: str) -> tuple[str, dict[str, str], float] | None:
    stripped = line.strip()
    if not stripped or stripped.startswith("#"):
        return None

    sample, value_text = split_prometheus_sample(stripped)
    if "{" in sample:
        name, raw_labels = sample.split("{", 1)
        if not raw_labels.endswith("}"):
            raise SyncError(f"Prometheus metric labels are not closed: {line}")
        labels = parse_prometheus_labels(raw_labels[:-1])
    else:
        name = sample
        labels = {}

    try:
        value = float(value_text.split()[0])
    except (IndexError, ValueError) as error:
        raise SyncError(f"Prometheus metric value is invalid: {line}") from error

    return name, labels, value


def build_status_by_public_key(
    metrics_text: str,
    now: int,
    handshake_max_age_seconds: int,
) -> dict[str, dict[str, Any]]:
    by_public_key: dict[str, dict[str, Any]] = {}
    seen_samples: set[tuple[str, str]] = set()
    for line in metrics_text.splitlines():
        parsed = parse_prometheus_metric_line(line)
        if parsed is None:
            continue

        metric_name, labels, value = parsed
        if metric_name not in (
            "wireguard_latest_handshake_delay_seconds",
            "wireguard_latest_handshake_seconds",
        ):
            continue

        public_key = labels.get("public_key")
        if not public_key:
            raise SyncError(f"{metric_name} is missing public_key label")

        sample_key = (metric_name, public_key)
        if sample_key in seen_samples:
            raise SyncError(
                f"WireGuard metrics have duplicate {metric_name} sample for {public_key}"
            )
        seen_samples.add(sample_key)

        status = by_public_key.setdefault(public_key, {"public_key": public_key})
        allowed_ips = [
            item.strip()
            for item in labels.get("allowed_ips", "").split(",")
            if item.strip()
        ]
        if allowed_ips and not status.get("allowed_ips"):
            status["allowed_ips"] = allowed_ips

        try:
            metric_value = int(value)
        except (OverflowError, ValueError) as error:
            raise SyncError(
                f"WireGuard metric {metric_name} value is not finite"
            ) from error

        if metric_name == "wireguard_latest_handshake_seconds":
            status["latest_handshake_seconds"] = metric_value
        else:
            status["latest_handshake_age_seconds"] = max(0, metric_value)

    if not by_public_key:
        raise SyncError("WireGuard metrics did not include latest handshake samples")

    for status in by_public_key.values():
        latest_handshake_seconds = status.get("latest_handshake_seconds")
        latest_handshake_age_seconds = status.get("latest_handshake_age_seconds")
        if latest_handshake_age_seconds is None and isinstance(
            latest_handshake_seconds, int
        ):
            if latest_handshake_seconds > 0:
                latest_handshake_age_seconds = max(0, now - latest_handshake_seconds)
            status["latest_handshake_age_seconds"] = latest_handshake_age_seconds

        connected = (
            latest_handshake_age_seconds is not None
            and latest_handshake_age_seconds <= handshake_max_age_seconds
        )
        if isinstance(latest_handshake_seconds, int) and latest_handshake_seconds <= 0:
            connected = False
        status["connected"] = connected
        status.setdefault("allowed_ips", [])
        status.setdefault("latest_handshake_seconds", 0)

    return by_public_key


def allowed_ips_contain_address(
    allowed_ips: list[str],
    address: ipaddress.IPv4Address,
) -> bool:
    for allowed_ip in allowed_ips:
        try:
            if ipaddress.ip_interface(allowed_ip).ip == address:
                return True
        except ValueError as error:
            raise SyncError(
                f"WireGuard metric has invalid allowed IP: {allowed_ip}"
            ) from error
    return False


def build_dns_records(
    peer_specs: list[PeerDnsSpec],
    status_by_public_key: dict[str, dict[str, Any]],
    ttl_seconds: int,
) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    for peer in peer_specs:
        status = status_by_public_key.get(peer.public_key)
        if status is None:
            raise SyncError(f"WireGuard metrics are missing peer: {peer.name}")

        allowed_ips = status.get("allowed_ips")
        if (
            isinstance(allowed_ips, list)
            and allowed_ips
            and not allowed_ips_contain_address(allowed_ips, peer.address)
        ):
            raise SyncError(
                f"WireGuard metrics allowed IPs for {peer.name} do not include {peer.address}"
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
        help="WireGuard exporter metrics URL, usually https://gw.home.arpa:9586/metrics.",
    )
    parser.add_argument(
        "--ca-file",
        default=os.environ.get("WG_HOME_STATUS_CA_FILE", ""),
        help="CA certificate used to verify an HTTPS WireGuard exporter.",
    )
    parser.add_argument(
        "--client-cert-file",
        default=os.environ.get("WG_HOME_STATUS_CLIENT_CERT_FILE", ""),
        help="Client certificate used for WireGuard exporter mTLS.",
    )
    parser.add_argument(
        "--client-key-file",
        default=os.environ.get("WG_HOME_STATUS_CLIENT_KEY_FILE", ""),
        help="Client key used for WireGuard exporter mTLS.",
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
        "--handshake-max-age-seconds",
        type=int,
        default=int(os.environ.get("WG_HOME_HANDSHAKE_MAX_AGE_SECONDS", "180")),
        help="Maximum age of a latest WireGuard handshake before disabling DNS.",
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
    if args.handshake_max_age_seconds < 1:
        print("error: --handshake-max-age-seconds must be positive", file=sys.stderr)
        return 1

    raw_peers_json = args.peers_json
    if args.peers_json_file:
        with open(args.peers_json_file, encoding="utf-8") as handle:
            raw_peers_json = handle.read()

    try:
        peer_specs = load_peer_dns_specs(raw_peers_json)
        metrics_text = fetch_metrics(
            args.status_url,
            timeout_seconds=args.timeout_seconds,
            ca_file=args.ca_file,
            client_cert_file=args.client_cert_file,
            client_key_file=args.client_key_file,
        )
        dns_records = build_dns_records(
            peer_specs=peer_specs,
            status_by_public_key=build_status_by_public_key(
                metrics_text=metrics_text,
                now=int(time.time()),
                handshake_max_age_seconds=args.handshake_max_age_seconds,
            ),
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
