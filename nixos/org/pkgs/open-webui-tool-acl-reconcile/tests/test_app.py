import json
import threading
from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler, HTTPServer
from typing import Mapping

import pytest

from open_webui_tool_acl_reconcile import app


def settings(**overrides):
    values = {
        "base_url": "http://open-webui.test",
        "admin_email": "admin@example.test",
        "admin_password": app.SecretStr("secret"),
        "group_name": "paperless-users",
        "tool_server_id": "paperless",
        "wait_seconds": 5.0,
        "poll_seconds": 1.0,
    }
    values.update(overrides)
    return app.Settings.model_validate(values)


def connection(server_id, grants=None):
    return app.ToolServerConnection(
        type="mcp",
        info=app.ConnectionInfo(id=server_id, name=server_id),
        config=app.ConnectionConfig(
            enable=True,
            access_grants=grants
            if grants is not None
            else [
                app.AccessGrant(
                    principal_type="user",
                    principal_id="*",
                    permission="read",
                )
            ],
        ),
    )


@dataclass
class FakeWaiter:
    current: float = 0
    sleeps: list[float] = field(default_factory=list)

    def monotonic(self) -> float:
        return self.current

    def sleep(self, seconds: float) -> None:
        self.sleeps.append(seconds)
        self.current += seconds


@dataclass
class QueueTransport:
    responses: list[object]
    calls: list[tuple[str, str, object | None]] = field(default_factory=list)

    def request(
        self,
        method: str,
        url: str,
        headers: Mapping[str, str],
        payload: object | None = None,
    ) -> object | None:
        self.calls.append((method, url, payload))
        response = self.responses.pop(0)
        if isinstance(response, Exception):
            raise response
        return response


def authenticated_client(responses):
    configured = settings()
    transport = QueueTransport(list(responses))
    client = app.OpenWebUIClient(
        configured,
        transport,
        token=app.SecretStr("test-token"),
    )
    return client, transport


def test_settings_validate_environment():
    loaded = app.Settings.from_environment(
        {
            "OPEN_WEBUI_BASE_URL": "http://open-webui.test/",
            "OPEN_WEBUI_ADMIN_EMAIL": "admin@example.test",
            "WEBUI_ADMIN_PASSWORD": "secret",
            "OPEN_WEBUI_ACCESS_GROUP": "paperless-users",
            "OPEN_WEBUI_TOOL_SERVER_ID": "paperless",
        }
    )

    assert loaded.base_url == "http://open-webui.test"
    assert loaded.admin_password.get_secret_value() == "secret"


def test_with_group_read_grant_replaces_only_target_acl():
    connections = [connection("other"), connection("paperless")]

    updated = app.with_group_read_grant(connections, "paperless", "group-id")

    assert updated[0] == connections[0]
    assert updated[1].config.access_grants == app.desired_grants("group-id")
    assert connections[1].config.access_grants[0].principal_id == "*"


@pytest.mark.parametrize(
    "connections",
    [[], [connection("paperless"), connection("paperless")]],
)
def test_with_group_read_grant_requires_one_target(connections):
    with pytest.raises(app.Error, match="expected one Open WebUI tool server"):
        app.with_group_read_grant(connections, "paperless", "group-id")


def test_verify_group_read_grant_rejects_additional_grants():
    grants = [
        *app.desired_grants("group-id"),
        app.AccessGrant(principal_type="user", principal_id="*", permission="read"),
    ]

    with pytest.raises(app.Error, match="did not retain"):
        app.verify_group_read_grant([connection("paperless", grants)], "paperless", "group-id")


def test_ensure_group_reuses_existing_group():
    client, transport = authenticated_client([[{"id": "group-id", "name": "paperless-users"}]])

    assert client.ensure_group() == "group-id"
    assert transport.calls[0][0] == "GET"


def test_ensure_group_creates_private_group():
    client, transport = authenticated_client([[], {"id": "group-id", "name": "paperless-users"}])

    assert client.ensure_group() == "group-id"
    assert transport.calls[1][2] == {
        "name": "paperless-users",
        "description": "Access synchronized from the SSO Paperless group.",
        "data": {"config": {"share": False}},
    }


def test_ensure_group_rejects_duplicate_names():
    client, _transport = authenticated_client(
        [
            [
                {"id": "group-one", "name": "paperless-users"},
                {"id": "group-two", "name": "paperless-users"},
            ]
        ]
    )

    with pytest.raises(app.Error, match="multiple Open WebUI groups"):
        client.ensure_group()


def test_sign_in_requires_token_and_sends_real_password():
    configured = settings()
    transport = QueueTransport([{"token": "issued-token"}])
    client = app.OpenWebUIClient(configured, transport)

    client.sign_in()

    assert client.token is not None
    assert client.token.get_secret_value() == "issued-token"
    assert transport.calls[0][2] == {
        "email": "admin@example.test",
        "password": "secret",
    }


def test_reconcile_tool_server_posts_and_verifies_acl():
    current = app.ToolServerConfiguration(
        TOOL_SERVER_CONNECTIONS=[connection("other"), connection("paperless")]
    )
    desired = current.model_copy(
        update={
            "connections": app.with_group_read_grant(current.connections, "paperless", "group-id")
        }
    )
    client, transport = authenticated_client(
        [
            current.model_dump(by_alias=True, exclude_none=True),
            desired.model_dump(by_alias=True, exclude_none=True),
        ]
    )

    client.reconcile_tool_server("group-id")

    assert transport.calls[1][0] == "POST"
    posted = app.ToolServerConfiguration.model_validate(transport.calls[1][2])
    app.verify_group_read_grant(posted.connections, "paperless", "group-id")


def test_configure_retries_and_reconciles_existing_group():
    current = app.ToolServerConfiguration(TOOL_SERVER_CONNECTIONS=[connection("paperless")])
    desired = current.model_copy(
        update={
            "connections": app.with_group_read_grant(current.connections, "paperless", "group-id")
        }
    )
    configured = settings()
    transport = QueueTransport(
        [
            app.Error("not ready"),
            {"status": "ok"},
            {"token": "issued-token"},
            [{"id": "group-id", "name": configured.group_name}],
            current.model_dump(by_alias=True, exclude_none=True),
            desired.model_dump(by_alias=True, exclude_none=True),
        ]
    )
    waiter = FakeWaiter()

    app.configure(
        configured,
        app.OpenWebUIClient(configured, transport),
        waiter,
    )

    assert waiter.sleeps == [1.0]
    assert [method for method, _url, _payload in transport.calls] == [
        "GET",
        "GET",
        "POST",
        "GET",
        "GET",
        "POST",
    ]


def test_wait_until_ready_times_out():
    configured = settings(wait_seconds=2.0)
    client = app.OpenWebUIClient(
        configured,
        QueueTransport([app.Error("down"), app.Error("still down")]),
    )

    with pytest.raises(app.Error, match="timed out waiting for Open WebUI"):
        client.wait_until_ready(FakeWaiter())


class OpenWebUIHandler(BaseHTTPRequestHandler):
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
    server = HTTPServer(("127.0.0.1", 0), OpenWebUIHandler)
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


def test_main_reports_invalid_environment(monkeypatch, capsys):
    monkeypatch.delenv("OPEN_WEBUI_BASE_URL", raising=False)

    assert app.main() == 1
    assert "invalid Open WebUI configuration" in capsys.readouterr().err
