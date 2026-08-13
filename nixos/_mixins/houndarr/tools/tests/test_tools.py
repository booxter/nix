from __future__ import annotations

import asyncio
import json
import threading
from collections.abc import Iterator, Mapping
from contextlib import contextmanager
from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit

import httpx
import pytest
from prometheus_client import CollectorRegistry
from prometheus_client.parser import text_string_to_metric_families

from houndarr_tools.cli import run_reconcile, run_status
from houndarr.services.instances import (
    CutoffPolicy,
    Instance,
    InstanceCore,
    InstanceTimestamps,
    InstanceType,
    MissingPolicy,
    RuntimeSnapshot,
    SchedulePolicy,
    TagFilterPolicy,
    UpgradePolicy,
)
from houndarr_tools.houndarr_store import HoundarrStore
from houndarr_tools.models import (
    CurrentInstance,
    DesiredInstance,
    Interface,
    ReconcileConfiguration,
    Value,
)
from houndarr_tools.reconcile import (
    BackendUnavailable,
    InstanceConflict,
    ReconcileError,
    reconcile_instances,
)
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


def values(registry: CollectorRegistry) -> dict[str, float]:
    return {sample.name: sample.value for metric in registry.collect() for sample in metric.samples}


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


@dataclass
class FakeStore:
    current: tuple[CurrentInstance, ...] = ()
    reachable: bool = True
    created: list[tuple[DesiredInstance, str, dict[str, Value]]] = field(default_factory=list)
    updated: list[tuple[int, dict[str, Value]]] = field(default_factory=list)

    async def list(self) -> tuple[CurrentInstance, ...]:
        return self.current

    async def verify(self, interface: Interface, url: str, api_key: str) -> bool:
        del interface, url, api_key
        return self.reachable

    async def create(
        self, desired: DesiredInstance, api_key: str, fields: Mapping[str, Value]
    ) -> None:
        self.created.append((desired, api_key, dict(fields)))

    async def update(self, instance_id: int, fields: Mapping[str, Value]) -> None:
        self.updated.append((instance_id, dict(fields)))


def desired(*, policy: object = None) -> DesiredInstance:
    return DesiredInstance.model_validate(
        {
            "key": "catalog",
            "displayName": "Lidarr",
            "interface": "lidarr",
            "url": "https://lidarr.services.example:9443",
            "enabled": True,
            "credential": {"name": "api-catalog", "format": "xml-element", "field": "ApiKey"},
            "policy": policy,
        }
    )


def write_credential(directory: Path, value: str = "secret-key") -> None:
    (directory / "api-catalog").write_text(
        f"<Config><ApiKey>{value}</ApiKey></Config>", encoding="utf-8"
    )


def run(store: FakeStore, item: DesiredInstance, credentials: Path) -> int:
    return asyncio.run(reconcile_instances(store, (item,), credentials, attempts=1, delay=0))


def test_reconcile_creates_connection_without_claiming_policy(tmp_path: Path) -> None:
    write_credential(tmp_path)
    store = FakeStore()

    assert run(store, desired(), tmp_path) == 1
    assert store.created[0][1:] == ("secret-key", {})


def test_reconcile_adopts_endpoint_and_updates_only_owned_fields(tmp_path: Path) -> None:
    write_credential(tmp_path, "new-key")
    current = CurrentInstance(
        id=7,
        name="Old label",
        interface="lidarr",
        url="https://lidarr.services.example:9443/",
        api_key="old-key",
        enabled=True,
        values={"batch_size": 50, "cooldown_days": 9},
    )
    store = FakeStore(current=(current,))
    item = desired(policy={"batch_size": 25, "missing_search_mode": "context"})

    assert run(store, item, tmp_path) == 1
    assert store.updated == [
        (
            7,
            {
                "name": "Lidarr",
                "api_key": "new-key",
                "batch_size": 25,
                "lidarr_search_mode": "artist_context",
            },
        )
    ]


def test_reconcile_uses_unique_name_fallback_and_leaves_unmanaged_instances(tmp_path: Path) -> None:
    write_credential(tmp_path)
    adopted = CurrentInstance(4, "Lidarr", "lidarr", "https://old.example", "secret-key", True, {})
    unrelated = CurrentInstance(8, "Radarr", "radarr", "https://other.example", "key", True, {})
    store = FakeStore(current=(adopted, unrelated))

    assert run(store, desired(), tmp_path) == 1
    assert store.updated == [(4, {"url": "https://lidarr.services.example:9443"})]


def test_reconcile_rejects_ambiguous_adoption(tmp_path: Path) -> None:
    write_credential(tmp_path)
    duplicate = CurrentInstance(1, "Lidarr", "lidarr", "https://old.example", "key", True, {})
    store = FakeStore(current=(duplicate, duplicate))

    with pytest.raises(InstanceConflict, match="multiple Houndarr instances"):
        run(store, desired(), tmp_path)


def test_reconcile_reports_unavailable_backend_and_bad_credential(tmp_path: Path) -> None:
    write_credential(tmp_path)
    with pytest.raises(BackendUnavailable, match="did not become ready"):
        run(FakeStore(reachable=False), desired(), tmp_path)

    (tmp_path / "api-catalog").write_text("<Config/>", encoding="utf-8")
    with pytest.raises(ReconcileError, match="is empty"):
        run(FakeStore(), desired(), tmp_path)


def test_run_reconcile_loads_declaration_and_credentials(tmp_path: Path) -> None:
    credentials = tmp_path / "credentials"
    credentials.mkdir()
    write_credential(credentials)
    configuration = tmp_path / "configuration.json"
    configuration.write_text(
        ReconcileConfiguration(instances=(desired(),)).model_dump_json(by_alias=True),
        encoding="utf-8",
    )
    store = FakeStore()

    changed = run_reconcile(
        ["--data-dir", str(tmp_path / "state"), "--config", str(configuration)],
        {"CREDENTIALS_DIRECTORY": str(credentials)},
        store_factory=lambda _: store,
    )

    assert changed == 1


def test_run_reconcile_requires_systemd_credentials(tmp_path: Path) -> None:
    with pytest.raises(ReconcileError, match="CREDENTIALS_DIRECTORY"):
        run_reconcile(["--data-dir", str(tmp_path), "--config", "missing"], {})


def test_store_converts_instances_and_delegates_writes() -> None:
    item = desired()
    instance = Instance(
        core=InstanceCore(3, "Lidarr", InstanceType.lidarr, item.url, "secret-key"),
        missing=MissingPolicy(batch_size=25),
        cutoff=CutoffPolicy(),
        upgrade=UpgradePolicy(),
        schedule=SchedulePolicy(),
        tag_filter=TagFilterPolicy(),
        snapshot=RuntimeSnapshot(),
        timestamps=InstanceTimestamps("created", "updated"),
    )

    @dataclass
    class FakeBackend:
        creations: list[tuple[str, bytes]] = field(default_factory=list)
        updates: list[tuple[int, bytes]] = field(default_factory=list)

        async def list(self, master_key: bytes) -> tuple[Instance, ...]:
            assert master_key == b"master-key"
            return (instance,)

        async def verify(self, interface: Interface, url: str, api_key: str) -> bool:
            return interface == "lidarr" and url == item.url and api_key == "secret-key"

        async def create(
            self,
            desired: DesiredInstance,
            api_key: str,
            fields: Mapping[str, Value],
            master_key: bytes,
        ) -> None:
            del desired, fields
            self.creations.append((api_key, master_key))

        async def update(
            self, instance_id: int, fields: Mapping[str, Value], master_key: bytes
        ) -> None:
            del fields
            self.updates.append((instance_id, master_key))

    backend = FakeBackend()
    store = HoundarrStore(
        "/state",
        backend,
        bootstrap=lambda _: (object(), object(), b"master-key"),
    )

    async def exercise() -> CurrentInstance:
        assert await store.verify("lidarr", item.url, "secret-key")
        await store.create(item, "secret-key", {"batch_size": 25})
        created = (await store.list())[0]
        await store.update(created.id, {"name": "Music catalog"})
        return created

    created = asyncio.run(exercise())

    assert created.name == "Lidarr"
    assert created.values["batch_size"] == 25
    assert backend.creations == [("secret-key", b"master-key")]
    assert backend.updates == [(3, b"master-key")]
