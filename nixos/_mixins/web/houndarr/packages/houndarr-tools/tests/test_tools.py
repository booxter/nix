from __future__ import annotations

import json
import threading
from collections.abc import Iterator
from contextlib import contextmanager
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit

import httpx
import pytest
from prometheus_client import CollectorRegistry
from prometheus_client.parser import text_string_to_metric_families

from houndarr_tools.cli import run_status, run_wait
from houndarr_tools.readiness import ReadinessTimeout, wait_for_backends
from houndarr_tools.status import collect_status, status_registry

Response = tuple[int, object]


@dataclass
class ServerState:
    responses: dict[str, list[Response]]
    users: set[str]


@contextmanager
def api_server(responses: dict[str, list[Response]]) -> Iterator[tuple[str, ServerState]]:
    state = ServerState(responses, set())

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self) -> None:
            user = self.headers.get("X-User")
            if user is not None:
                state.users.add(user)
            path = urlsplit(self.path).path
            route = state.responses.get(path, [(404, {"error": "not found"})])
            status, body = route.pop(0) if len(route) > 1 else route[0]
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
        yield f"http://{host}:{port}", state
    finally:
        server.shutdown()
        thread.join()
        server.server_close()


class ManualTime:
    def __init__(self) -> None:
        self.now = 0.0

    def clock(self) -> float:
        return self.now

    def sleep(self, duration: float) -> None:
        self.now += duration


def values(registry: CollectorRegistry) -> dict[str, float]:
    return {sample.name: sample.value for metric in registry.collect() for sample in metric.samples}


def test_wait_succeeds_after_backend_becomes_ready() -> None:
    manual = ManualTime()
    with api_server({"/ping": [(503, {}), (200, {})]}) as (base_url, _):
        with httpx.Client() as client:
            wait_for_backends(
                client,
                [f"{base_url}/ping"],
                timeout=10,
                interval=1,
                clock=manual.clock,
                sleep=manual.sleep,
            )
    assert manual.now == 1


def test_wait_times_out_with_backend_names() -> None:
    manual = ManualTime()
    with api_server({"/ping": [(503, {})]}) as (base_url, _):
        with httpx.Client() as client:
            with pytest.raises(ReadinessTimeout, match="/ping"):
                wait_for_backends(
                    client,
                    [f"{base_url}/ping"],
                    timeout=2,
                    interval=1,
                    clock=manual.clock,
                    sleep=manual.sleep,
                )


def test_status_counts_only_enabled_instances_with_active_errors() -> None:
    body = {
        "instances": [
            {"enabled": True, "active_error": True},
            {"enabled": True, "active_error": None},
            {"enabled": False, "active_error": True},
        ]
    }
    with api_server({"/api/status": [(200, body)]}) as (base_url, state):
        with httpx.Client() as client:
            snapshot = collect_status(client, f"{base_url}/api/status", now=123)

    assert snapshot.ok
    assert snapshot.enabled_instances == 2
    assert snapshot.active_error_instances == 1
    assert state.users == {"houndarr-monitor"}
    metrics = values(status_registry(snapshot))
    assert metrics["host_observability_houndarr_status_ok"] == 1
    assert metrics["host_observability_houndarr_active_error_instances"] == 1


def test_status_failure_writes_zero_metrics_and_returns_failure(tmp_path: Path) -> None:
    metrics_path = tmp_path / "houndarr.prom"
    with api_server({"/api/status": [(200, {"instances": "invalid"})]}) as (base_url, _):
        ok = run_status(
            ["--url", f"{base_url}/api/status", "--metrics-file", str(metrics_path)],
            now=123,
        )

    assert not ok
    families = list(text_string_to_metric_families(metrics_path.read_text(encoding="utf-8")))
    samples = {sample.name: sample.value for family in families for sample in family.samples}
    assert samples["host_observability_houndarr_status_ok"] == 0
    assert samples["host_observability_houndarr_enabled_instances"] == 0


def test_wait_command_uses_all_ready_backends() -> None:
    manual = ManualTime()
    routes = {"/one": [(200, {})], "/two": [(200, {})]}
    with api_server(routes) as (base_url, _):
        run_wait(
            [
                "--url",
                f"{base_url}/one",
                "--url",
                f"{base_url}/two",
                "--timeout-seconds",
                "2",
            ],
            clock=manual.clock,
            sleep=manual.sleep,
        )
    assert manual.now == 0
