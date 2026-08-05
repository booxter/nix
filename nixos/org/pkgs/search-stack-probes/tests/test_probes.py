from __future__ import annotations

import json
import threading
from collections.abc import Iterator
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit

import httpx
from prometheus_client import CollectorRegistry
from prometheus_client.parser import text_string_to_metric_families

from search_stack_probes.cli import run_searchless
from search_stack_probes.metrics import searchless_registry
from search_stack_probes.models import SearchlessSnapshot
from search_stack_probes.probes import collect_searchless

Response = tuple[int, object]


@contextmanager
def api_server(routes: dict[str, Response]) -> Iterator[str]:
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self) -> None:
            status, body = routes.get(urlsplit(self.path).path, (404, {"error": "not found"}))
            encoded = json.dumps(body).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(encoded)))
            self.end_headers()
            self.wfile.write(encoded)

        def log_message(self, format: str, *args: object) -> None:
            del format, args

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever)
    thread.start()
    try:
        host, port = server.server_address
        yield f"http://{host}:{port}"
    finally:
        server.shutdown()
        thread.join()
        server.server_close()


def values(registry: CollectorRegistry) -> dict[str, float]:
    return {sample.name: sample.value for metric in registry.collect() for sample in metric.samples}


def valid_searchless_routes() -> dict[str, Response]:
    return {
        "/health": (200, {"status": "ok"}),
        "/test-connection": (
            200,
            {"paperless_connected": True, "vector_store_initialized": True},
        ),
        "/sync/status": (
            200,
            {"paperless_documents": 12, "chroma_chunks": 34, "bulk_sync_limit": None},
        ),
    }


def test_searchless_collects_typed_endpoint_state() -> None:
    with api_server(valid_searchless_routes()) as base_url:
        with httpx.Client(base_url=base_url) as client:
            snapshot = collect_searchless(client, now=123)

    assert snapshot.collection_success
    assert snapshot.paperless_connected
    assert snapshot.vector_store_initialized
    assert snapshot.paperless_documents == 12
    assert snapshot.chroma_chunks == 34
    assert snapshot.bulk_sync_limit == 0
    metrics = values(searchless_registry(snapshot))
    assert metrics["searchless_metrics_collection_success"] == 1
    assert metrics["searchless_chroma_chunks"] == 34


def test_searchless_keeps_independent_probe_failures_visible() -> None:
    routes = valid_searchless_routes()
    routes["/sync/status"] = (200, {"paperless_documents": -1})
    with api_server(routes) as base_url:
        with httpx.Client(base_url=base_url) as client:
            snapshot = collect_searchless(client, now=123)

    assert snapshot.health_success
    assert snapshot.test_connection_success
    assert not snapshot.sync_status_success
    assert not snapshot.collection_success
    assert snapshot.paperless_documents == 0


def test_commands_write_parseable_prometheus_metrics(tmp_path: Path) -> None:
    with api_server(valid_searchless_routes()) as base_url:
        searchless_metrics = tmp_path / "searchless.prom"
        run_searchless(
            ["--base-url", base_url, "--metrics-file", str(searchless_metrics)],
            now=123,
        )

    searchless_families = list(
        text_string_to_metric_families(searchless_metrics.read_text(encoding="utf-8"))
    )
    assert any(
        family.name == "searchless_metrics_collection_success" for family in searchless_families
    )


def test_collection_success_requires_every_endpoint() -> None:
    snapshot = SearchlessSnapshot(
        timestamp=123,
        health_success=True,
        test_connection_success=True,
        sync_status_success=False,
        paperless_connected=True,
        vector_store_initialized=True,
        paperless_documents=0,
        chroma_chunks=0,
        bulk_sync_limit=0,
    )
    assert not snapshot.collection_success
