import importlib.util
import json
import os
import pathlib
import sys

import pytest


MODULE_PATH = pathlib.Path(
    os.environ.get("UPTIMEROBOT_SYNC_MAIN", pathlib.Path(__file__).with_name("main.py"))
)
SPEC = importlib.util.spec_from_file_location("uptimerobot_sync", MODULE_PATH)
uptimerobot_sync = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = uptimerobot_sync
SPEC.loader.exec_module(uptimerobot_sync)


class FakeClient:
    def __init__(self, monitors):
        self.monitors = monitors
        self.created = []
        self.updated = []
        self.deleted = []

    def list_monitors(self):
        return self.monitors

    def create_monitor(self, payload):
        self.created.append(payload)

    def update_monitor(self, monitor_id, payload):
        self.updated.append((monitor_id, payload))

    def delete_monitor(self, monitor_id):
        self.deleted.append(monitor_id)


def service(id="search", title="Search", url="https://search.example/health"):
    return uptimerobot_sync.Service(id=id, title=title, url=url)


def test_create_missing_monitor():
    client = FakeClient([])

    actions = uptimerobot_sync.reconcile(client, [service()], 300)

    assert actions == ["create search (https://search.example/health)"]
    assert client.created == [
        {
            "friendlyName": "Search",
            "type": "HTTP",
            "url": "https://search.example/health",
            "interval": 300,
            "tagNames": ["nix-inventory", "nix-service-search"],
        }
    ]


def test_adopt_monitor_by_url_and_preserve_existing_tags():
    client = FakeClient(
        [
            {
                "id": 42,
                "friendlyName": "Old name",
                "type": "HTTP",
                "url": "https://search.example/health",
                "interval": 300,
                "tags": [{"name": "personal"}],
            }
        ]
    )

    uptimerobot_sync.reconcile(client, [service()], 300)

    assert client.updated == [
        (
            42,
            {
                "friendlyName": "Search",
                "type": "HTTP",
                "url": "https://search.example/health",
                "interval": 300,
                "tagNames": ["nix-inventory", "nix-service-search", "personal"],
            },
        )
    ]


def test_update_managed_monitor_by_service_tag_when_url_changes():
    client = FakeClient(
        [
            {
                "id": 7,
                "friendlyName": "Search",
                "type": "HTTP",
                "url": "https://old.example/health",
                "interval": 300,
                "tags": ["nix-inventory", "nix-service-search"],
            }
        ]
    )

    uptimerobot_sync.reconcile(client, [service()], 300)

    assert client.updated == [
        (
            7,
            {
                "friendlyName": "Search",
                "type": "HTTP",
                "url": "https://search.example/health",
                "interval": 300,
                "tagNames": ["nix-inventory", "nix-service-search"],
            },
        )
    ]
    assert client.created == []
    assert client.deleted == []


def test_delete_only_stale_managed_monitor():
    client = FakeClient(
        [
            {
                "id": 1,
                "url": "https://old.example",
                "tags": ["nix-inventory", "nix-service-old"],
            },
            {
                "id": 2,
                "url": "https://manual.example",
                "tags": ["personal"],
            },
        ]
    )

    actions = uptimerobot_sync.reconcile(client, [], 300)

    assert actions == ["delete old (1)"]
    assert client.deleted == [1]


def test_noop_when_monitor_matches():
    client = FakeClient(
        [
            {
                "id": 7,
                "friendlyName": "Search",
                "type": "HTTP",
                "url": "https://search.example/health",
                "interval": 300,
                "tags": ["nix-inventory", "nix-service-search"],
            }
        ]
    )

    assert uptimerobot_sync.reconcile(client, [service()], 300) == []
    assert client.updated == []


def test_dry_run_does_not_mutate():
    client = FakeClient([])

    actions = uptimerobot_sync.reconcile(client, [service()], 300, dry_run=True)

    assert actions == ["create search (https://search.example/health)"]
    assert client.created == []


def test_ambiguous_adoption_fails():
    client = FakeClient(
        [
            {"id": 1, "url": "https://search.example/health"},
            {"id": 2, "url": "https://search.example/health"},
        ]
    )

    with pytest.raises(uptimerobot_sync.UptimeRobotError, match="multiple monitors"):
        uptimerobot_sync.reconcile(client, [service()], 300)


def test_client_lists_v3_monitors_with_bearer_auth(monkeypatch):
    class Response:
        def __enter__(self):
            return self

        def __exit__(self, *_args):
            return None

        def read(self):
            return json.dumps({"monitors": [{"id": 17}]}).encode()

    def urlopen(request, timeout):
        assert request.full_url == "https://api.example/v3/monitors"
        assert request.get_header("Authorization") == "Bearer secret"
        assert timeout == 30
        return Response()

    monkeypatch.setattr(uptimerobot_sync.urllib.request, "urlopen", urlopen)

    client = uptimerobot_sync.UptimeRobotClient("https://api.example/v3", "secret")

    assert client.list_monitors() == [{"id": 17}]
