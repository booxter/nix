import json
import threading
import urllib.parse
from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler, HTTPServer
from typing import Mapping

import pytest

from paperless_gpt_configure import app


def settings(**overrides):
    values = {
        "base_url": "http://paperless.test",
        "api_token": app.SecretStr("test-token"),
        "auto_tag": "paperless-gpt-auto",
        "auto_ocr_tag": "paperless-gpt-ocr-auto",
        "ocr_complete_tag": "paperless-gpt-ocr-complete",
        "auto_ocr_workflow_name": "Auto OCR with paperless-gpt",
        "post_ocr_workflow_name": "Auto classify after paperless-gpt OCR",
        "wait_seconds": 5.0,
        "poll_seconds": 1.0,
    }
    values.update(overrides)
    return app.Settings.model_validate(values)


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
class MemoryTransport:
    tags: list[dict[str, object]] = field(default_factory=list)
    workflows: list[dict[str, object]] = field(default_factory=list)
    readiness_failures: int = 0
    calls: list[tuple[str, str, object | None]] = field(default_factory=list)

    def request(
        self,
        method: str,
        url: str,
        headers: Mapping[str, str],
        payload: object | None = None,
    ) -> object | None:
        path = urllib.parse.urlparse(url).path
        self.calls.append((method, path, payload))
        assert headers["Authorization"] == "Token test-token"
        if path == "/api/status/":
            if self.readiness_failures > 0:
                self.readiness_failures -= 1
                raise OSError("not ready")
            return {"status": "ok"}
        if path == "/api/tags/" and method == "GET":
            return {"results": self.tags}
        if path == "/api/tags/" and method == "POST":
            assert isinstance(payload, dict)
            created = {**payload, "id": len(self.tags) + 1}
            self.tags.append(created)
            return created
        if path == "/api/workflows/" and method == "GET":
            return {"results": self.workflows}
        if path == "/api/workflows/" and method == "POST":
            assert isinstance(payload, dict)
            created = {**payload, "id": len(self.workflows) + 10}
            self.workflows.append(created)
            return created
        if path.startswith("/api/workflows/") and method == "PATCH":
            assert isinstance(payload, dict)
            workflow_id = int(path.rstrip("/").rsplit("/", 1)[1])
            index = next(
                index
                for index, workflow in enumerate(self.workflows)
                if workflow["id"] == workflow_id
            )
            self.workflows[index] = {**payload, "id": workflow_id}
            return self.workflows[index]
        raise AssertionError(f"unexpected request: {method} {path}")


def test_settings_load_token_and_validate_environment(tmp_path):
    token_file = tmp_path / "token"
    token_file.write_text("secret-token\n", encoding="utf-8")

    loaded = app.Settings.from_environment(
        {
            "PAPERLESS_API_TOKEN_FILE": str(token_file),
            "PAPERLESS_BASE_URL": "http://paperless.test/",
            "PAPERLESS_GPT_AUTO_TAG": "auto",
            "PAPERLESS_GPT_AUTO_OCR_TAG": "auto-ocr",
            "PAPERLESS_GPT_OCR_COMPLETE_TAG": "ocr-complete",
            "PAPERLESS_GPT_AUTO_OCR_WORKFLOW_NAME": "OCR",
            "PAPERLESS_GPT_POST_OCR_WORKFLOW_NAME": "Classify",
        }
    )

    assert loaded.base_url == "http://paperless.test"
    assert loaded.api_token.get_secret_value() == "secret-token"


def test_settings_reject_invalid_base_url(tmp_path):
    token_file = tmp_path / "token"
    token_file.write_text("token\n", encoding="utf-8")

    with pytest.raises(app.Error, match="base_url must be an HTTP"):
        app.Settings.from_environment(
            {
                "PAPERLESS_API_TOKEN_FILE": str(token_file),
                "PAPERLESS_BASE_URL": "paperless.test",
                "PAPERLESS_GPT_AUTO_TAG": "auto",
                "PAPERLESS_GPT_AUTO_OCR_TAG": "auto-ocr",
                "PAPERLESS_GPT_OCR_COMPLETE_TAG": "ocr-complete",
                "PAPERLESS_GPT_AUTO_OCR_WORKFLOW_NAME": "OCR",
                "PAPERLESS_GPT_POST_OCR_WORKFLOW_NAME": "Classify",
            }
        )


def test_desired_workflows_sequence_ocr_before_metadata():
    configured = settings()
    tags = {
        configured.auto_tag: app.Tag(id=1, name=configured.auto_tag),
        configured.auto_ocr_tag: app.Tag(id=3, name=configured.auto_ocr_tag),
        configured.ocr_complete_tag: app.Tag(id=4, name=configured.ocr_complete_tag),
    }

    workflows = app.desired_workflows(configured, tags)

    assert [workflow.name for workflow in workflows] == [
        "Auto OCR with paperless-gpt",
        "Auto classify after paperless-gpt OCR",
    ]
    assert workflows[0].actions[0].assign_tags == [3]
    assert workflows[1].triggers[0].filter_has_tags == [4]
    assert workflows[1].triggers[0].filter_has_not_tags == [1]


def test_workflow_payload_preserves_nested_object_ids():
    desired = app.DesiredWorkflow(
        "Existing workflow",
        triggers=(app.WorkflowComponent(type=3, filter_has_tags=[4]),),
        actions=(
            app.WorkflowComponent(type=1, assign_tags=[1]),
            app.WorkflowComponent(type=2, remove_tags=[4]),
        ),
    )
    existing = app.Workflow(
        id=10,
        name=desired.name,
        triggers=[app.WorkflowComponent(id=20, type=2)],
        actions=[app.WorkflowComponent(id=30, type=1)],
    )

    payload = app.workflow_payload(desired, existing)

    assert payload.model_dump(exclude_none=True) == {
        "name": "Existing workflow",
        "order": 0,
        "enabled": True,
        "triggers": [{"id": 20, "type": 3, "filter_has_tags": [4]}],
        "actions": [
            {"id": 30, "type": 1, "assign_tags": [1]},
            {"type": 2, "remove_tags": [4]},
        ],
    }


def test_configure_retries_then_creates_tags_and_workflows():
    configured = settings()
    transport = MemoryTransport(readiness_failures=2)
    waiter = FakeWaiter()
    client = app.PaperlessClient(configured, transport)

    app.configure(configured, client, waiter)

    assert waiter.sleeps == [1.0, 1.0]
    assert [tag["name"] for tag in transport.tags] == [
        configured.auto_tag,
        configured.auto_ocr_tag,
        configured.ocr_complete_tag,
    ]
    assert [workflow["name"] for workflow in transport.workflows] == [
        configured.auto_ocr_workflow_name,
        configured.post_ocr_workflow_name,
    ]


def test_configure_reuses_tags_and_patches_existing_workflow():
    configured = settings()
    transport = MemoryTransport(
        tags=[
            {"id": 1, "name": configured.auto_tag.upper()},
            {"id": 2, "name": configured.auto_ocr_tag},
            {"id": 3, "name": configured.ocr_complete_tag},
        ],
        workflows=[
            {
                "id": 10,
                "name": configured.auto_ocr_workflow_name,
                "triggers": [{"id": 20, "type": 9}],
                "actions": [{"id": 30, "type": 9}],
            }
        ],
    )

    app.configure(
        configured,
        app.PaperlessClient(configured, transport),
        FakeWaiter(),
    )

    patched = transport.workflows[0]
    assert patched["id"] == 10
    assert patched["triggers"][0]["id"] == 20
    assert patched["actions"][0]["id"] == 30
    assert not any(method == "POST" and path == "/api/tags/" for method, path, _ in transport.calls)


def test_wait_until_ready_times_out():
    configured = settings(wait_seconds=2.0)
    client = app.PaperlessClient(configured, MemoryTransport(readiness_failures=10))

    with pytest.raises(app.Error, match="timed out waiting for Paperless API"):
        client.wait_until_ready(FakeWaiter())


def test_client_rejects_invalid_tag_response():
    configured = settings()
    transport = MemoryTransport(tags=[{"id": "not-an-integer", "name": "tag"}])

    with pytest.raises(app.Error, match="invalid tag list response"):
        app.PaperlessClient(configured, transport).list_tags()


class PaperlessHandler(BaseHTTPRequestHandler):
    received: object | None = None

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        type(self).received = json.loads(self.rfile.read(length))
        if self.path == "/failure":
            self.send_response(422)
            self.end_headers()
            self.wfile.write(b"bad payload")
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps({"accepted": True}).encode("utf-8"))

    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"not-json")

    def log_message(self, format, *args):
        pass


def test_urllib_transport_handles_json_and_errors():
    server = HTTPServer(("127.0.0.1", 0), PaperlessHandler)
    thread = threading.Thread(target=server.serve_forever)
    thread.start()
    base_url = f"http://127.0.0.1:{server.server_port}"
    transport = app.UrllibTransport()
    try:
        assert transport.request("POST", f"{base_url}/success", {}, {"name": "value"}) == {
            "accepted": True
        }
        assert PaperlessHandler.received == {"name": "value"}
        with pytest.raises(app.Error, match="HTTP 422: bad payload"):
            transport.request("POST", f"{base_url}/failure", {}, {})
        with pytest.raises(app.Error, match="returned invalid JSON"):
            transport.request("GET", f"{base_url}/invalid", {})
    finally:
        server.shutdown()
        thread.join()
        server.server_close()


def test_main_reports_invalid_environment(monkeypatch, capsys):
    monkeypatch.delenv("PAPERLESS_API_TOKEN_FILE", raising=False)

    assert app.main() == 1
    assert "invalid Paperless configuration" in capsys.readouterr().err
