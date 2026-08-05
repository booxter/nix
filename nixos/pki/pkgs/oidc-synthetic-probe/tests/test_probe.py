from __future__ import annotations

import json
import io
import threading
from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

import pytest
from prometheus_client.parser import text_string_to_metric_families

from oidc_synthetic_probe.app import Config, parse_args, run
from oidc_synthetic_probe.models import StateFile


@dataclass
class ProbeFixture:
    base_url: str = ""
    redirect_uri: str = ""
    authorization_state: str = ""
    wrong_state: bool = False
    search_failure: bool = False
    navigation_paths: list[str] = field(default_factory=list)


def handler_for(fixture: ProbeFixture) -> type[BaseHTTPRequestHandler]:
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, _format: str, *_arguments: object) -> None:
            pass

        def send_payload(
            self,
            payload: bytes,
            *,
            content_type: str,
            status: int = 200,
            headers: dict[str, str] | None = None,
        ) -> None:
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(payload)))
            for name, value in (headers or {}).items():
                self.send_header(name, value)
            self.end_headers()
            self.wfile.write(payload)

        def send_json(
            self,
            payload: object,
            *,
            status: int = 200,
            headers: dict[str, str] | None = None,
        ) -> None:
            self.send_payload(
                json.dumps(payload).encode(),
                content_type="application/json",
                status=status,
                headers=headers,
            )

        def redirect(self, location: str) -> None:
            self.send_payload(
                b"",
                content_type="text/plain",
                status=302,
                headers={"Location": location},
            )

        def read_body(self) -> bytes:
            return self.rfile.read(int(self.headers.get("Content-Length", "0")))

        def require_navigation(self) -> None:
            fixture.navigation_paths.append(urlsplit(self.path).path)
            if self.headers.get("Accept") != "text/html":
                self.send_error(400, "missing navigation Accept header")
                raise AssertionError("missing navigation Accept header")
            if self.headers.get("Sec-Fetch-Mode") != "navigate":
                self.send_error(400, "missing navigation mode")
                raise AssertionError("missing navigation mode")

        def do_GET(self) -> None:  # noqa: N802
            parsed = urlsplit(self.path)
            if parsed.path.endswith("/.well-known/openid-configuration"):
                self.send_json(
                    {
                        "jwks_uri": fixture.base_url + "/jwks",
                        "authorization_endpoint": fixture.base_url + "/authorize",
                        "token_endpoint": fixture.base_url + "/token",
                        "userinfo_endpoint": fixture.base_url + "/userinfo",
                    }
                )
                return
            if parsed.path == "/jwks":
                self.send_json({"keys": [{"kid": "one"}]})
                return
            if parsed.path == "/authorize":
                self.require_navigation()
                if "bearer=session" not in self.headers.get("Cookie", ""):
                    self.send_error(401, "missing bearer cookie")
                    return
                fixture.authorization_state = parse_qs(parsed.query)["state"][0]
                self.send_payload(
                    b'<input type="hidden" name="consent_token" value="token&amp;value">',
                    content_type="text/html",
                )
                return
            if parsed.path == "/userinfo":
                if self.headers.get("Authorization") != "Bearer access":
                    self.send_error(401, "missing access token")
                    return
                self.send_json({"sub": "probe-user"})
                return
            if parsed.path == "/search/":
                self.require_navigation()
                if fixture.search_failure:
                    self.send_error(503, "search unavailable")
                else:
                    self.redirect("/oauth2/start")
                return
            if parsed.path == "/oauth2/start":
                self.require_navigation()
                self.redirect("/search/result")
                return
            if parsed.path == "/search/result":
                self.require_navigation()
                self.send_payload(b"search", content_type="text/html")
                return
            self.send_error(404, parsed.path)

        def do_POST(self) -> None:  # noqa: N802
            parsed = urlsplit(self.path)
            body = self.read_body()
            if parsed.path == "/v1/auth":
                step = json.loads(body)["step"]
                if "init2" in step:
                    self.send_json({"state": {"choose": ["password"]}})
                elif "begin" in step:
                    self.send_json({"state": {"continue": ["password"]}})
                else:
                    self.send_json(
                        {"state": {"success": "ok"}},
                        headers={"Set-Cookie": "bearer=session; Path=/; HttpOnly"},
                    )
                return
            if parsed.path == "/ui/oauth2/consent":
                form = parse_qs(body.decode())
                if form.get("consent_token") != ["token&value"]:
                    self.send_error(400, "bad consent token")
                    return
                state = "wrong" if fixture.wrong_state else fixture.authorization_state
                self.redirect(f"{fixture.redirect_uri}?code=code&state={state}")
                return
            if parsed.path == "/token":
                form = parse_qs(body.decode())
                if form.get("code") != ["code"] or not form.get("code_verifier"):
                    self.send_error(400, "bad token request")
                    return
                self.send_json({"access_token": "access"})
                return
            self.send_error(404, parsed.path)

    return Handler


class ProbeServer:
    def __init__(self, fixture: ProbeFixture) -> None:
        self.fixture = fixture
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), handler_for(fixture))
        host, port = self.server.server_address
        fixture.base_url = f"http://{host}:{port}"
        fixture.redirect_uri = fixture.base_url + "/callback"
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    def __enter__(self) -> ProbeServer:
        self.thread.start()
        return self

    def __exit__(self, *_arguments: object) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()


def config_for(fixture: ProbeFixture, directory: Path) -> Config:
    password = directory / "password"
    password.write_text("secret\n")
    return Config(
        idp_url=fixture.base_url,
        username="probe-user",
        password_file=password,
        client_id="probe-client",
        redirect_uri=fixture.redirect_uri,
        searxng_url=fixture.base_url + "/search/",
        metrics_file=directory / "metrics.prom",
        state_file=directory / "state.json",
        timeout=2,
    )


def metric_value(path: Path, name: str, labels: dict[str, str]) -> float:
    for family in text_string_to_metric_families(path.read_text()):
        for sample in family.samples:
            if sample.name == name and sample.labels == labels:
                return float(sample.value)
    raise AssertionError(f"missing metric {name}{labels}")


def test_complete_oidc_and_proxy_flow_uses_real_http(tmp_path: Path) -> None:
    fixture = ProbeFixture()
    with ProbeServer(fixture):
        config = config_for(fixture, tmp_path)
        assert run(config) == 0

    for probe in ("kanidm", "searxng"):
        assert (
            metric_value(
                config.metrics_file,
                "host_observability_oidc_synthetic_probe_ok",
                {"probe": probe},
            )
            == 1
        )
    assert (
        metric_value(
            config.metrics_file,
            "host_observability_oidc_synthetic_probe_phase_ok",
            {"probe": "kanidm", "phase": "authorize"},
        )
        == 1
    )
    state = StateFile.model_validate_json(config.state_file.read_bytes())
    assert state.probes["kanidm"].last_success > 0
    assert state.probes["searxng"].last_success > 0
    assert fixture.navigation_paths == [
        "/authorize",
        "/search/",
        "/oauth2/start",
        "/search/result",
    ]
    assert config.metrics_file.stat().st_mode & 0o777 == 0o644
    assert config.state_file.stat().st_mode & 0o777 == 0o600


@pytest.mark.parametrize(
    ("wrong_state", "search_failure", "failed_probe"),
    [(True, False, "kanidm"), (False, True, "searxng")],
)
def test_protocol_failures_are_reported_as_metrics(
    tmp_path: Path,
    wrong_state: bool,
    search_failure: bool,
    failed_probe: str,
) -> None:
    fixture = ProbeFixture(wrong_state=wrong_state, search_failure=search_failure)
    errors = io.StringIO()
    with ProbeServer(fixture):
        config = config_for(fixture, tmp_path)
        assert run(config, errors) == 0
    assert (
        metric_value(
            config.metrics_file,
            "host_observability_oidc_synthetic_probe_ok",
            {"probe": failed_probe},
        )
        == 0
    )
    assert f"{failed_probe} failed:" in errors.getvalue()


def test_missing_password_still_emits_failure_metrics(tmp_path: Path) -> None:
    metrics = tmp_path / "metrics.prom"
    config = Config(
        idp_url="http://127.0.0.1:9",
        username="probe-user",
        password_file=tmp_path / "missing",
        client_id="probe-client",
        redirect_uri="http://127.0.0.1:9/callback",
        searxng_url="http://127.0.0.1:9/search/",
        metrics_file=metrics,
    )
    assert run(config) == 0
    assert (
        metric_value(
            metrics,
            "host_observability_oidc_synthetic_probe_ok",
            {"probe": "kanidm"},
        )
        == 0
    )


def test_cli_builds_typed_config_and_rejects_bad_timeout(tmp_path: Path) -> None:
    arguments = [
        "--idp-url",
        "https://id.example.test",
        "--username",
        "probe",
        "--password-file",
        str(tmp_path / "password"),
        "--client-id",
        "client",
        "--redirect-uri",
        "https://probe.example.test/callback",
        "--searxng-url",
        "https://search.example.test",
        "--metrics-file",
        str(tmp_path / "metrics"),
    ]
    assert parse_args(arguments).client_id == "client"
    with pytest.raises(SystemExit):
        parse_args([*arguments, "--timeout", "0"])
