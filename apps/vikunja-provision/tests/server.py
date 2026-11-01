from __future__ import annotations

import base64
import hashlib
import json
import threading
from collections.abc import Iterator
from contextlib import contextmanager
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlencode, urlsplit

import httpx2
from pydantic import BaseModel, SecretStr
from vikunja_provision.models import BotSpec, ProvisionError, Share, TokenSpec

from .fakes import MemoryVikunja


@dataclass
class Grant:
    client_id: str
    redirect_uri: str
    challenge: str


class TestServer(ThreadingHTTPServer):
    __test__ = False

    def __init__(self) -> None:
        super().__init__(("127.0.0.1", 0), Handler)
        self.backend = MemoryVikunja()
        self.status = 200
        self.malformed = False
        self.wrong_page = False
        self.empty_page = False
        self.grant: Grant | None = None
        self.oauth_failure = False
        self.oauth_empty_token = False

    @property
    def url(self) -> str:
        return f"http://127.0.0.1:{self.server_port}"


class Handler(BaseHTTPRequestHandler):
    server: TestServer

    def respond(self, body: object, status: int = 200) -> None:
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        if status == 302:
            self.send_header("Location", self.server.url + "/redirected")
        self.end_headers()
        self.wfile.write(json.dumps(body).encode())

    def paginated(self, records: list[BaseModel]) -> None:
        query = parse_qs(urlsplit(self.path).query)
        page = int(query.get("page", ["1"])[0])
        items = records[page - 1 : page]  # Deliberately cap pages at one item.
        if self.server.empty_page:
            items = []

        self.respond(
            {
                "$schema": "/api/v2/schemas/page.json",
                "items": [item.model_dump(mode="json") for item in items],
                "page": 123 if self.server.wrong_page else page,
                "total_pages": 2 if self.server.empty_page else len(records),
            }
        )

    def authorized(self) -> bool:
        if self.headers.get("Authorization") != "Bearer user-session-secret":
            self.respond({"message": "user-session-secret"}, 401)
            return False

        if self.server.status != 200:
            self.respond({"message": "user-session-secret"}, self.server.status)
            return False

        if self.server.malformed:
            self.respond({"bad": "tk_secret_response"})
            return False

        return True

    def do_GET(self) -> None:
        parsed = urlsplit(self.path)
        query = parse_qs(parsed.query)
        if parsed.path == "/oauth/authorize":
            assert query["response_type"] == ["code"]
            assert query["code_challenge_method"] == ["S256"]
            self.server.grant = Grant(
                client_id=query["client_id"][0],
                redirect_uri=query["redirect_uri"][0],
                challenge=query["code_challenge"][0],
            )
            self.send_response(302)
            callback = urlencode({"code": "one-time-code", "state": query["state"][0]})
            self.send_header("Location", self.server.grant.redirect_uri + "?" + callback)
            self.end_headers()
            return

        if not self.authorized():
            return

        backend = self.server.backend
        if parsed.path == "/api/v2/user/bots":
            self.paginated(list(backend.bots()))
        elif parsed.path == "/api/v2/projects":
            self.paginated(list(backend.projects()))
        elif parsed.path == "/api/v2/tokens":
            self.paginated(list(backend.tokens(int(query["owner_id"][0]))))
        elif parsed.path.startswith("/api/v2/projects/"):
            self.paginated(list(backend.shares(int(parsed.path.split("/")[4]))))
        else:
            self.respond({}, 404)

    def do_POST(self) -> None:
        data = self.rfile.read(int(self.headers["Content-Length"]))
        if self.path == "/api/v2/oauth/token":
            self.exchange_code(data)
            return

        if not self.authorized():
            return

        backend = self.server.backend
        if self.path == "/api/v2/user/bots":
            bot = backend.create_bot(BotSpec.model_validate_json(data))
            self.respond(bot.model_dump(mode="json"), 201)
        elif self.path == "/api/v2/tokens":

            class TokenRequest(TokenSpec):
                owner_id: int

            request = TokenRequest.model_validate_json(data)
            spec = TokenSpec.model_validate(request.model_dump(exclude={"owner_id"}))
            issued = backend.issue_token(request.owner_id, spec)
            body = issued.model_dump(mode="json")
            body["token"] = issued.token.get_secret_value()
            self.respond(body, 201)
        elif self.path.startswith("/api/v2/projects/"):
            project_id = int(self.path.split("/")[4])
            backend.set_share(project_id, Share.model_validate_json(data), exists=False)
            self.respond({}, 201)
        else:
            self.respond({}, 404)

    def exchange_code(self, data: bytes) -> None:
        grant = self.server.grant
        assert grant is not None
        fields = parse_qs(data.decode())
        verifier = fields["code_verifier"][0]
        challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(
            b"="
        )
        valid = (
            fields["grant_type"] == ["authorization_code"]
            and fields["code"] == ["one-time-code"]
            and fields["client_id"] == [grant.client_id]
            and fields["redirect_uri"] == [grant.redirect_uri]
            and challenge.decode() == grant.challenge
        )
        if not valid or self.server.oauth_failure:
            self.respond({"error": "invalid_grant", "error_description": "secret_code"}, 400)
            return

        self.respond(
            {
                "access_token": "" if self.server.oauth_empty_token else "user-session-secret",
                "token_type": "bearer",
                "refresh_token": "refresh-secret",
            }
        )

    def do_PATCH(self) -> None:
        if not self.authorized():
            return

        class BotUpdate(BotSpec):
            status: int

        request = BotUpdate.model_validate_json(
            self.rfile.read(int(self.headers["Content-Length"]))
        )
        bot_id = int(self.path.rsplit("/", 1)[1])
        bot = next(bot for bot in self.server.backend.bots() if bot.id == bot_id)
        assert request.status == 0
        desired = BotSpec(username=request.username, name=request.name)
        self.server.backend.update_bot(bot, desired)
        self.respond({})

    def do_PUT(self) -> None:
        if not self.authorized():
            return

        data = self.rfile.read(int(self.headers["Content-Length"]))
        project_id = int(self.path.split("/")[4])
        self.server.backend.set_share(project_id, Share.model_validate_json(data), exists=True)
        self.respond({})

    def do_DELETE(self) -> None:
        if not self.authorized():
            return

        self.server.backend.delete_token(int(self.path.rsplit("/", 1)[1]))
        self.respond({}, 204)

    def log_message(self, format: str, *args: object) -> None:
        pass


@contextmanager
def running_server() -> Iterator[TestServer]:
    with TestServer() as server:
        thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.05})
        thread.start()
        try:
            yield server
        finally:
            server.shutdown()
            thread.join()


class BrowserPrompt:
    def show(self, url: str) -> None:
        with httpx2.Client(follow_redirects=True, timeout=5) as browser:
            browser.get(url).raise_for_status()


class InterruptedPrompt:
    def show(self, url: str) -> None:
        raise KeyboardInterrupt


class UnusedPrompt:
    def show(self, url: str) -> None:
        raise ProvisionError("Unexpected login prompt")


SESSION = SecretStr("user-session-secret")
