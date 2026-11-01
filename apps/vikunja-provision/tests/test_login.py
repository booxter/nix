from __future__ import annotations

from urllib.parse import parse_qs, urlencode, urlsplit

import httpx2
import pytest
from vikunja_provision.cli import ConsoleAuthorizationPrompt
from vikunja_provision.login import callback_listener, login
from vikunja_provision.models import ProvisionError

from .server import SESSION, BrowserPrompt, running_server


@pytest.mark.parametrize("failure", ["oauth_failure", "oauth_empty_token"])
def test_failed_token_exchange_never_exposes_server_content(failure: str) -> None:
    with running_server() as server:
        setattr(server, failure, True)
        with pytest.raises(ProvisionError, match="SSO token exchange failed") as error:
            login(server.url, BrowserPrompt())

        assert "secret" not in str(error.value)


class CallbackPrompt:
    def __init__(self, *, deny: bool = False) -> None:
        self.deny = deny

    def show(self, url: str) -> None:
        params = parse_qs(urlsplit(url).query)
        response = {"state": params["state"][0]}
        if self.deny:
            response["error"] = "access_denied"
        else:
            response["code"] = "authorization-code"

        httpx2.get(params["redirect_uri"][0] + "?" + urlencode(response)).raise_for_status()


class SilentPrompt:
    def show(self, url: str) -> None:
        pass


def test_sso_denial_is_reported() -> None:
    with pytest.raises(ProvisionError, match="denied"):
        login("https://example.test", CallbackPrompt(deny=True))


def test_sso_timeout_closes_callback_listener() -> None:
    with pytest.raises(ProvisionError, match="timed out"):
        login("https://example.test", SilentPrompt(), timeout=0.01)


def test_callback_rejects_unrelated_requests_and_wrong_state() -> None:
    with callback_listener("expected-state") as (uri, results), httpx2.Client() as client:
        assert client.get(uri.replace("/callback", "/other")).status_code == 404
        assert client.get(uri, params={"state": "wrong", "code": "forged"}).status_code == 400
        assert client.get(uri, params={"state": "expected-state"}).status_code == 400
        assert client.get(uri + "?" + "&".join(f"field{i}=1" for i in range(11))).status_code == 400
        assert results.empty()

        response = client.get(uri, params={"state": "expected-state", "code": "valid"})
        assert response.status_code == 200
        assert response.headers["cache-control"] == "no-store"
        assert (
            client.get(uri, params={"state": "expected-state", "code": "stale"}).status_code == 200
        )
        assert "valid" in str(results.get_nowait())


def test_browser_sso_uses_pkce_and_returns_a_user_session() -> None:
    with running_server() as server:
        assert login(server.url, BrowserPrompt()) == SESSION


def test_console_prompt_provides_a_clickable_login_url(capsys: pytest.CaptureFixture[str]) -> None:
    ConsoleAuthorizationPrompt().show("https://example.test/oauth/authorize?state=example")
    captured = capsys.readouterr()
    assert "https://example.test/oauth/authorize?state=example" in captured.err
    assert captured.out == ""
