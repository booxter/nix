from __future__ import annotations

import json
import threading
from collections.abc import Iterator
from contextlib import contextmanager
from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

import httpx
import pytest
from pinepods_tools.api import PinepodsApiError
from pinepods_tools.subscriptions import HttpSubscriptionApi, enforce


@dataclass
class State:
    podcasts: dict[int, dict[str, bool]] = field(default_factory=dict)
    writes: list[tuple[int, str]] = field(default_factory=list)
    downloads: object = True
    invalid_pods: bool = False
    invalid_setting: bool = False


@contextmanager
def server(state: State) -> Iterator[str]:
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self) -> None:
            path = urlsplit(self.path)
            endpoint = path.path.removeprefix("/api/data/")
            if self.headers.get("Api-Key") != "secret":
                self.respond(401, {})
            elif endpoint == "get_user":
                self.respond(200, {"retrieved_id": 2})
            elif endpoint == "download_status":
                self.respond(200, state.downloads)
            elif endpoint == "return_pods/2":
                pods: object = (
                    "invalid" if state.invalid_pods else [{"podcastid": p} for p in state.podcasts]
                )
                self.respond(200, {"pods": pods})
            elif endpoint.startswith("get_"):
                params = parse_qs(path.query)
                if params.get("user_id") != ["2"]:
                    self.respond(403, {})
                    return
                podcast = int(params["podcast_id"][0])
                enabled: object = state.podcasts[podcast][endpoint[4:]]
                self.respond(200, {"enabled": "invalid" if state.invalid_setting else enabled})
            else:
                self.respond(404, {})

        def do_POST(self) -> None:
            endpoint = urlsplit(self.path).path.removeprefix("/api/data/")
            body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            if self.headers.get("Api-Key") != "secret" or body["user_id"] != 2:
                self.respond(403, {})
                return
            podcast = body["podcast_id"]
            if endpoint == "get_auto_download_status":
                self.respond(200, {"auto_download": state.podcasts[podcast]["auto_download"]})
                return
            setting = "auto_download" if endpoint == "enable_auto_download" else endpoint[7:]
            state.podcasts[podcast][setting] = body.get("auto_download", body.get("enabled"))
            state.writes.append((podcast, setting))
            self.respond(200, {"detail": "updated"})

        def respond(self, status: int, body: object) -> None:
            encoded = json.dumps(body).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(encoded)))
            self.end_headers()
            self.wfile.write(encoded)

        def log_message(self, format: str, *args: object) -> None:
            pass

    httpd = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{httpd.server_port}"
    finally:
        httpd.shutdown()
        thread.join()
        httpd.server_close()


def settings() -> dict[str, bool]:
    return {
        "auto_download": False,
        "auto_transcribe": False,
        "auto_ad_detect": False,
        "ad_skip_auto_activate": True,
    }


def test_enforces_new_subscriptions_and_is_idempotent() -> None:
    state = State(podcasts={10: settings()})
    expected = {
        "auto_download": True,
        "auto_transcribe": True,
        "auto_ad_detect": True,
        "ad_skip_auto_activate": False,
    }
    with server(state) as url, httpx.Client(base_url=url, trust_env=False) as client:
        api = HttpSubscriptionApi(client, "secret")
        assert enforce(api) == 1
        assert state.podcasts[10] == expected
        assert len(state.writes) == 4
        assert enforce(api) == 1
        assert len(state.writes) == 4
        state.podcasts[11] = settings()
        state.podcasts[10]["ad_skip_auto_activate"] = True
        assert enforce(api) == 2
        assert state.podcasts[10] == expected
        assert state.podcasts[11] == expected
        assert len(state.writes) == 9


@pytest.mark.parametrize("downloads", [False, "true", None])
def test_disabled_or_invalid_global_downloads_fail(downloads: object) -> None:
    state = State(podcasts={10: settings()}, downloads=downloads)
    with (
        server(state) as url,
        httpx.Client(base_url=url, trust_env=False) as client,
        pytest.raises(PinepodsApiError, match="download"),
    ):
        enforce(HttpSubscriptionApi(client, "secret"))
    assert not state.writes


def test_bad_key_fails_without_disclosing_key() -> None:
    with (
        server(State()) as url,
        httpx.Client(base_url=url, trust_env=False) as client,
        pytest.raises(PinepodsApiError) as error,
    ):
        enforce(HttpSubscriptionApi(client, "wrong secret"))
    assert "wrong secret" not in str(error.value)


@pytest.mark.parametrize("invalid_pods", [True, False])
def test_invalid_podcast_or_setting_fails(invalid_pods: bool) -> None:
    podcast_settings = settings()
    podcast_settings["auto_download"] = True
    state = State(
        podcasts={10: podcast_settings},
        invalid_pods=invalid_pods,
        invalid_setting=not invalid_pods,
    )
    with (
        server(state) as url,
        httpx.Client(base_url=url, trust_env=False) as client,
        pytest.raises(PinepodsApiError, match="Invalid PinePods response"),
    ):
        enforce(HttpSubscriptionApi(client, "secret"))
    assert not state.writes
