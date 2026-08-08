from __future__ import annotations

import json
from collections.abc import Iterator
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import Thread
from typing import Any

import pytest

from wg_home_dns_sync.app import build_tls_context, main
from wg_home_dns_sync.metrics import build_dns_records, build_status_by_public_key
from wg_home_dns_sync.models import SyncError, load_peer_dns_specs


PEERS = [
    {
        "name": "laptop",
        "publicKey": "laptop-key",
        "domain": "Laptop.Home.Arpa.",
        "address": "10.42.0.2",
    },
    {
        "name": "phone",
        "publicKey": "phone-key",
        "domain": "phone.home.arpa",
        "address": "10.42.0.3",
    },
]

METRICS = """\
# TYPE wireguard_latest_handshake_delay_seconds gauge
wireguard_latest_handshake_delay_seconds{public_key="laptop-key",allowed_ips="10.42.0.2/32"} 30
wireguard_latest_handshake_delay_seconds{public_key="phone-key",allowed_ips="10.42.0.3/32"} 400
"""


class Service:
    def __init__(self) -> None:
        self.mutations: list[tuple[str, str, dict[str, Any]]] = []
        self.api_keys: list[str | None] = []
        self.policies: list[dict[str, Any]] = [
            {
                "id": "dns-1",
                "type": "A_RECORD",
                "domain": "laptop.home.arpa",
                "enabled": False,
                "ttlSeconds": 60,
                "ipv4Address": "10.42.0.2",
            }
        ]


@contextmanager
def service_server(service: Service) -> Iterator[str]:
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, format: str, *args: object) -> None:
            del format, args

        def _json(self, payload: object) -> None:
            body = json.dumps(payload).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self) -> None:
            if self.path == "/metrics":
                body = METRICS.encode()
                self.send_response(200)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            service.api_keys.append(self.headers.get("X-API-Key"))
            if self.path.startswith("/proxy/network/integration/v1/sites?"):
                self._json(
                    {
                        "data": [
                            {
                                "id": "site-1",
                                "internalReference": "default",
                                "name": "Default",
                            }
                        ],
                        "count": 1,
                        "totalCount": 1,
                    }
                )
                return
            if self.path.startswith("/proxy/network/integration/v1/sites/site-1/dns/policies?"):
                self._json(
                    {
                        "data": service.policies,
                        "count": len(service.policies),
                        "totalCount": len(service.policies),
                    }
                )
                return
            self.send_error(404)

        def _mutate(self) -> None:
            length = int(self.headers.get("Content-Length", "0"))
            payload = json.loads(self.rfile.read(length))
            service.api_keys.append(self.headers.get("X-API-Key"))
            service.mutations.append((self.command, self.path, payload))
            self._json({"id": "result-id"})

        do_POST = _mutate
        do_PUT = _mutate

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = Thread(target=server.serve_forever)
    thread.start()
    try:
        host, port = server.server_address
        yield f"http://{host}:{port}"
    finally:
        server.shutdown()
        thread.join()
        server.server_close()


def cli_args(base_url: str, output_records: Path | None = None) -> list[str]:
    arguments = [
        "--status-url",
        f"{base_url}/metrics",
        "--peers-json",
        json.dumps(PEERS),
        "--unifi-base-url",
        base_url,
        "--unifi-api-key",
        "secret",
    ]
    if output_records is not None:
        arguments.extend(("--output-records", str(output_records)))
    return arguments


def test_main_reconciles_records_through_real_http_service(tmp_path: Path, capsys: Any) -> None:
    service = Service()
    output_records = tmp_path / "records.json"
    with service_server(service) as base_url:
        assert main(cli_args(base_url, output_records)) == 0

    summary = json.loads(capsys.readouterr().out)
    assert summary["unifi_sync"]["changed_count"] == 2
    assert summary["dns_records"] == [
        {
            "domain": "laptop.home.arpa",
            "enabled": True,
            "ipv4Address": "10.42.0.2",
            "ttlSeconds": 60,
            "type": "A_RECORD",
        },
        {
            "domain": "phone.home.arpa",
            "enabled": False,
            "ipv4Address": "10.42.0.3",
            "ttlSeconds": 60,
            "type": "A_RECORD",
        },
    ]
    assert json.loads(output_records.read_text()) == summary["dns_records"]
    assert [mutation[0] for mutation in service.mutations] == ["PUT", "POST"]
    assert all(api_key == "secret" for api_key in service.api_keys)


def test_main_dry_run_reads_but_does_not_mutate(capsys: Any) -> None:
    service = Service()
    with service_server(service) as base_url:
        assert main([*cli_args(base_url), "--dry-run"]) == 0

    summary = json.loads(capsys.readouterr().out)
    assert summary["unifi_sync"]["dry_run"] is True
    assert summary["unifi_sync"]["changed_count"] == 2
    assert service.mutations == []


def test_peer_inventory_normalizes_and_rejects_duplicates() -> None:
    specs = load_peer_dns_specs(json.dumps(PEERS))
    assert specs[0].domain == "laptop.home.arpa"
    duplicate = [PEERS[0], {**PEERS[1], "publicKey": "laptop-key"}]
    with pytest.raises(SyncError, match="duplicate peer DNS publicKey"):
        load_peer_dns_specs(json.dumps(duplicate))


def test_metrics_require_expected_peers_and_allowed_ips() -> None:
    valid_statuses = build_status_by_public_key(METRICS, now=1_000, handshake_max_age_seconds=180)
    records = build_dns_records(load_peer_dns_specs(json.dumps(PEERS)), valid_statuses, 30)
    assert [record.enabled for record in records] == [True, False]

    wrong_allowed_ip = METRICS.replace("10.42.0.2/32", "10.42.0.99/32")
    wrong_statuses = build_status_by_public_key(
        wrong_allowed_ip, now=1_000, handshake_max_age_seconds=180
    )
    with pytest.raises(SyncError, match="allowed IPs for laptop"):
        build_dns_records(load_peer_dns_specs(json.dumps(PEERS)), wrong_statuses, 30)

    with pytest.raises(SyncError, match="missing peer: phone"):
        build_dns_records(
            load_peer_dns_specs(json.dumps(PEERS)),
            {"laptop-key": valid_statuses["laptop-key"]},
            30,
        )


def test_metrics_reject_duplicate_and_nonfinite_samples() -> None:
    duplicate = METRICS + METRICS.splitlines()[1] + "\n"
    with pytest.raises(SyncError, match="duplicate wireguard_latest_handshake"):
        build_status_by_public_key(duplicate, now=1_000, handshake_max_age_seconds=180)

    nonfinite = METRICS.replace(" 30", " NaN")
    with pytest.raises(SyncError, match="not finite"):
        build_status_by_public_key(nonfinite, now=1_000, handshake_max_age_seconds=180)


def test_https_metrics_require_all_mtls_files() -> None:
    with pytest.raises(SyncError, match="--ca-file, --client-cert-file, --client-key-file"):
        build_tls_context("https://gw.home.arpa/metrics", "", "", "")
