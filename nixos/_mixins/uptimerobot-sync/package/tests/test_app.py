import json
import threading
from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler, HTTPServer

import pytest

from uptimerobot_sync import app


def service(id="search", title="Search", url="https://search.example/health"):
    return app.Service(id=id, title=title, url=url)


def monitor(
    id,
    *,
    title="Search",
    url="https://search.example/health",
    interval=300,
    type="HTTP",
    timeout=30,
):
    return app.Monitor(
        id=id,
        friendlyName=title,
        url=url,
        interval=interval,
        type=type,
        timeout=timeout,
    )


@dataclass
class FakeClient:
    monitors: list[app.Monitor]
    created: list[app.MonitorPayload] = field(default_factory=list)
    updated: list[tuple[app.MonitorId, app.MonitorPayload]] = field(default_factory=list)
    deleted: list[app.MonitorId] = field(default_factory=list)

    def list_monitors(self):
        return self.monitors

    def create_monitor(self, payload):
        self.created.append(payload)

    def update_monitor(self, monitor_id, payload):
        self.updated.append((monitor_id, payload))

    def delete_monitor(self, monitor_id):
        self.deleted.append(monitor_id)


def test_create_missing_monitor():
    client = FakeClient([])

    actions = app.reconcile(client, [service()], 300)

    assert actions == ["create search (https://search.example/health)"]
    assert client.created == [app.desired_monitor(service(), 300)]


def test_adopt_monitor_by_url():
    client = FakeClient([monitor(42, title="Old name")])

    app.reconcile(client, [service()], 300)

    assert client.updated == [(42, app.desired_monitor(service(), 300))]


def test_adopt_monitor_by_title_when_url_changes():
    client = FakeClient([monitor(7, url="https://old.example/health")])

    app.reconcile(client, [service()], 300)

    assert client.updated == [(7, app.desired_monitor(service(), 300))]
    assert client.created == []
    assert client.deleted == []


def test_delete_all_monitors_absent_from_inventory():
    client = FakeClient(
        [
            monitor(1, title="Old", url="https://old.example"),
            monitor(2, title="Manual", url="https://manual.example"),
        ]
    )

    actions = app.reconcile(client, [], 300)

    assert actions == ["delete Old (1)", "delete Manual (2)"]
    assert client.deleted == [1, 2]


def test_noop_when_monitor_matches():
    client = FakeClient([monitor(7)])

    assert app.reconcile(client, [service()], 300) == []
    assert client.updated == []


def test_dry_run_does_not_mutate():
    client = FakeClient([])

    actions = app.reconcile(client, [service()], 300, dry_run=True)

    assert actions == ["create search (https://search.example/health)"]
    assert client.created == []


def test_ambiguous_adoption_fails():
    client = FakeClient([monitor(1), monitor(2)])

    with pytest.raises(app.Error, match="multiple monitors"):
        app.reconcile(client, [service()], 300)


def test_duplicate_monitor_ids_fail():
    client = FakeClient([monitor(1), monitor(1, title="Other")])

    with pytest.raises(app.Error, match="duplicate monitor id"):
        app.reconcile(client, [], 300)


def test_inventory_validates_duplicates_and_types(tmp_path):
    inventory = tmp_path / "inventory.json"
    inventory.write_text(
        json.dumps(
            [
                {"id": "one", "title": "One", "url": "https://one.test"},
                {"id": "one", "title": "Two", "url": "https://two.test"},
            ]
        ),
        encoding="utf-8",
    )

    with pytest.raises(app.Error, match="duplicate inventory service id"):
        app.load_services(inventory)

    inventory.write_text(json.dumps([{"id": 1, "title": "One", "url": "url"}]))
    with pytest.raises(app.Error, match="invalid inventory JSON"):
        app.load_services(inventory)


@dataclass
class RecordingTransport:
    response: object
    request_data: tuple[str, str, object | None] | None = None

    def request(self, method, url, headers, payload=None):
        assert headers["Authorization"] == "Bearer secret"
        self.request_data = (method, url, payload)
        return self.response


def test_client_validates_monitor_list_and_bearer_auth():
    transport = RecordingTransport({"data": [{"id": 17, "friendlyName": "Monitor"}]})
    client = app.UptimeRobotClient("https://api.example/v3/", "secret", transport)

    assert client.list_monitors() == [app.Monitor(id=17, friendlyName="Monitor")]
    assert transport.request_data == (
        "GET",
        "https://api.example/v3/monitors",
        None,
    )


class UptimeRobotHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        payload = json.loads(self.rfile.read(length))
        if payload.get("fail"):
            self.send_response(422)
            self.end_headers()
            self.wfile.write(b"bad payload")
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps({"accepted": payload}).encode("utf-8"))

    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"not-json")

    def log_message(self, format, *args):
        pass


def test_httpx_transport_handles_json_and_errors():
    server = HTTPServer(("127.0.0.1", 0), UptimeRobotHandler)
    thread = threading.Thread(target=server.serve_forever)
    thread.start()
    base_url = f"http://127.0.0.1:{server.server_port}"
    transport = app.HttpxTransport()
    try:
        assert transport.request("POST", f"{base_url}/success", {}, {"ok": True}) == {
            "accepted": {"ok": True}
        }
        with pytest.raises(app.Error, match="HTTP 422: bad payload"):
            transport.request("POST", f"{base_url}/failure", {}, {"fail": True})
        with pytest.raises(app.Error, match="returned invalid JSON"):
            transport.request("GET", f"{base_url}/invalid", {})
    finally:
        server.shutdown()
        thread.join()
        server.server_close()


def test_main_rejects_empty_api_key(tmp_path, capsys):
    key_file = tmp_path / "api-key"
    inventory = tmp_path / "inventory.json"
    key_file.write_text("\n", encoding="utf-8")
    inventory.write_text("[]\n", encoding="utf-8")

    result = app.main(
        [
            "--api-key-file",
            str(key_file),
            "--inventory-json-file",
            str(inventory),
        ]
    )

    assert result == 1
    assert "API key file is empty" in capsys.readouterr().err
