from __future__ import annotations

import secrets
import threading
from collections.abc import Iterator
from contextlib import contextmanager, suppress
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from queue import Empty, Full, Queue
from typing import Protocol
from urllib.parse import parse_qs, urlsplit

import httpx2
from authlib.integrations.base_client.errors import OAuthError
from authlib.integrations.httpx_client import OAuth2Client
from pydantic import BaseModel, Field, SecretStr, ValidationError
from vikunja_provision.models import ProvisionError


class AuthorizationPrompt(Protocol):
    def show(self, url: str) -> None: ...


class LoginToken(BaseModel):
    access_token: SecretStr = Field(min_length=1)


@contextmanager
def callback_listener(state: str) -> Iterator[tuple[str, Queue[str | ProvisionError]]]:
    results: Queue[str | ProvisionError] = Queue(maxsize=1)

    class CallbackHandler(BaseHTTPRequestHandler):
        def do_GET(self) -> None:
            parsed = urlsplit(self.path)
            if parsed.path != "/callback":
                self.send_error(404)
                return

            try:
                query = parse_qs(parsed.query, max_num_fields=10)
            except ValueError:
                self.send_error(400)
                return

            if query.get("state") != [state]:
                self.send_error(400, "Invalid OAuth state")
                return

            result: str | ProvisionError
            if "error" in query:
                result = ProvisionError("SSO authorization was denied")
            elif len(query.get("code", [])) == 1:
                result = redirect_uri + "?" + parsed.query
            else:
                self.send_error(400, "Missing authorization code")
                return

            # A stale tab must not overwrite the result from the first valid callback.
            with suppress(Full):
                results.put_nowait(result)

            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(b"Authorization received. Return to the terminal.\n")

        def log_message(self, format: str, *args: object) -> None:
            # The request URL contains a one-time authorization code.
            pass

    with ThreadingHTTPServer(("127.0.0.1", 0), CallbackHandler) as listener:
        redirect_uri = f"http://127.0.0.1:{listener.server_port}/callback"
        thread = threading.Thread(target=listener.serve_forever, kwargs={"poll_interval": 0.05})
        thread.start()
        try:
            yield redirect_uri, results
        finally:
            listener.shutdown()
            thread.join()


def login(server: str, prompt: AuthorizationPrompt, *, timeout: float = 300) -> SecretStr:
    state = secrets.token_urlsafe(32)
    verifier = secrets.token_urlsafe(64)
    with (
        callback_listener(state) as (redirect_uri, results),
        OAuth2Client(
            client_id="vikunja-provision",
            redirect_uri=redirect_uri,
            code_challenge_method="S256",
            token_endpoint_auth_method="none",
            timeout=20,
            follow_redirects=False,
        ) as client,
    ):
        url, _ = client.create_authorization_url(
            server + "/oauth/authorize", state=state, code_verifier=verifier
        )
        prompt.show(url)
        try:
            callback = results.get(timeout=timeout)
        except Empty as error:
            raise ProvisionError("SSO login timed out; run the command again") from error

        if isinstance(callback, ProvisionError):
            raise callback

        try:
            token = client.fetch_token(
                server + "/api/v2/oauth/token",
                authorization_response=callback,
                code_verifier=verifier,
            )
            return LoginToken.model_validate(token).access_token
        except (httpx2.HTTPError, OAuthError, ValidationError, ValueError) as error:
            raise ProvisionError("SSO token exchange failed; run the command again") from error
