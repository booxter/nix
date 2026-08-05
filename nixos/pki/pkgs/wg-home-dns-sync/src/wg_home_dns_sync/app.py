from __future__ import annotations

import argparse
import json
import os
import ssl
import sys
import time
from collections.abc import Sequence
from pathlib import Path

import httpx
from unifi_sync.client import UnifiLegacyClient
from unifi_sync.dns import policy_payload, sync_records
from unifi_sync.errors import UnifiError

from .metrics import build_dns_records, build_status_by_public_key
from .models import SyncError, load_peer_dns_specs


class Arguments(argparse.Namespace):
    status_url: str
    ca_file: str
    client_cert_file: str
    client_key_file: str
    timeout_seconds: float
    ttl_seconds: int
    handshake_max_age_seconds: int
    peers_json: str
    peers_json_file: str
    output_records: str
    unifi_base_url: str
    unifi_site: str
    unifi_api_key: str
    insecure_tls: bool
    debug: bool
    dry_run: bool


def build_tls_context(
    url: str,
    ca_file: str,
    client_cert_file: str,
    client_key_file: str,
) -> ssl.SSLContext | bool:
    if not url.lower().startswith("https://"):
        return True
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
    try:
        context = ssl.create_default_context(cafile=ca_file)
        context.load_cert_chain(certfile=client_cert_file, keyfile=client_key_file)
    except OSError as error:
        raise SyncError(f"failed to load WireGuard exporter TLS credentials: {error}") from error
    return context


def fetch_metrics(
    url: str,
    timeout_seconds: float,
    ca_file: str,
    client_cert_file: str,
    client_key_file: str,
) -> str:
    verify = build_tls_context(url, ca_file, client_cert_file, client_key_file)
    try:
        with httpx.Client(verify=verify, timeout=timeout_seconds, follow_redirects=True) as client:
            response = client.get(url)
            response.raise_for_status()
            return response.text
    except httpx.HTTPError as error:
        raise SyncError(f"failed to fetch WireGuard metrics from {url}: {error}") from error


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="wg-home-dns-sync",
        description="Sync WireGuard peer DNS overrides directly to UniFi.",
    )
    parser.add_argument(
        "--status-url",
        default=os.environ.get("WG_HOME_STATUS_URL", ""),
        help="WireGuard exporter metrics URL.",
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
        help="Maximum latest-handshake age before disabling DNS.",
    )
    parser.add_argument(
        "--peers-json",
        default=os.environ.get("WG_HOME_DNS_PEERS_JSON", ""),
        help="JSON array of WireGuard peer DNS specifications.",
    )
    parser.add_argument(
        "--peers-json-file",
        default=os.environ.get("WG_HOME_DNS_PEERS_JSON_FILE", ""),
        help="Path to a JSON array of WireGuard peer DNS specifications.",
    )
    parser.add_argument(
        "--output-records",
        default="",
        help="Optional path to write the generated DNS records JSON.",
    )
    parser.add_argument(
        "--unifi-base-url",
        default=os.environ.get("UNIFI_BASE_URL", ""),
        help="UniFi base URL. Defaults to UNIFI_BASE_URL.",
    )
    parser.add_argument(
        "--unifi-site",
        default=os.environ.get("UNIFI_SITE", "default"),
        help="UniFi site. Defaults to UNIFI_SITE or 'default'.",
    )
    parser.add_argument(
        "--unifi-api-key",
        default=os.environ.get("UNIFI_API_KEY", ""),
        help="UniFi API key. Defaults to UNIFI_API_KEY.",
    )
    parser.add_argument(
        "--insecure-tls",
        action="store_true",
        help="Disable UniFi TLS verification for local troubleshooting.",
    )
    parser.add_argument("--debug", action="store_true", help="Print UniFi request details.")
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Read UniFi state and report changes without applying them.",
    )
    return parser


def _read_peers(arguments: Arguments) -> str:
    if not arguments.peers_json_file:
        return arguments.peers_json
    try:
        return Path(arguments.peers_json_file).read_text(encoding="utf-8")
    except OSError as error:
        raise SyncError(f"failed to read peer DNS JSON: {error}") from error


def run(arguments: Arguments, now: int) -> dict[str, object]:
    peer_specs = load_peer_dns_specs(_read_peers(arguments))
    metrics_text = fetch_metrics(
        arguments.status_url,
        timeout_seconds=arguments.timeout_seconds,
        ca_file=arguments.ca_file,
        client_cert_file=arguments.client_cert_file,
        client_key_file=arguments.client_key_file,
    )
    records = build_dns_records(
        peer_specs=peer_specs,
        status_by_public_key=build_status_by_public_key(
            metrics_text=metrics_text,
            now=now,
            handshake_max_age_seconds=arguments.handshake_max_age_seconds,
        ),
        ttl_seconds=arguments.ttl_seconds,
    )
    record_payloads = [policy_payload(record) for record in records]
    if arguments.output_records:
        try:
            Path(arguments.output_records).write_text(
                json.dumps(record_payloads, indent=2, sort_keys=True) + "\n",
                encoding="utf-8",
            )
        except OSError as error:
            raise SyncError(f"failed to write DNS records JSON: {error}") from error

    client = UnifiLegacyClient(
        base_url=arguments.unifi_base_url,
        api_key=arguments.unifi_api_key,
        site=arguments.unifi_site,
        verify_tls=not arguments.insecure_tls,
        debug=arguments.debug,
    )
    result: dict[str, object] = {
        "status_url": arguments.status_url,
        "dry_run": arguments.dry_run,
        "dns_records": record_payloads,
        "unifi_sync": sync_records(
            client=client,
            requested_site=arguments.unifi_site,
            records=records,
            dry_run=arguments.dry_run,
        ),
    }
    if arguments.output_records:
        result["output_records"] = arguments.output_records
    return result


def main(argv: Sequence[str] | None = None) -> int:
    parser = build_parser()
    arguments = parser.parse_args(argv, namespace=Arguments())
    if not arguments.status_url:
        parser.error("missing --status-url")
    if arguments.timeout_seconds <= 0:
        parser.error("--timeout-seconds must be positive")
    if arguments.ttl_seconds < 0:
        parser.error("--ttl-seconds must be non-negative")
    if arguments.handshake_max_age_seconds < 1:
        parser.error("--handshake-max-age-seconds must be positive")

    try:
        result = run(arguments, now=int(time.time()))
    except (SyncError, UnifiError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
