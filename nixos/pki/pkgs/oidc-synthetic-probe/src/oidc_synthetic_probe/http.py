from __future__ import annotations

import json
from collections.abc import Mapping
from html import unescape
from html.parser import HTMLParser
from types import TracebackType
from urllib.parse import urljoin, urlsplit, urlunsplit

import httpx

from .errors import ProbeError


class HiddenInputParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.hidden_inputs: dict[str, str] = {}

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag.lower() != "input":
            return
        fields = {key.lower(): value or "" for key, value in attrs}
        if fields.get("type", "").lower() != "hidden":
            return
        if name := fields.get("name"):
            self.hidden_inputs[name] = unescape(fields.get("value", ""))


def redacted_url(url: str) -> str:
    parts = urlsplit(url)
    return urlunsplit((parts.scheme, parts.netloc, parts.path, "", ""))


class HttpClient:
    def __init__(self, timeout: float) -> None:
        self._client = httpx.Client(
            timeout=timeout,
            follow_redirects=False,
            headers={
                "User-Agent": "oidc-synthetic-probe/1.0",
                "Accept": "*/*",
            },
        )

    def __enter__(self) -> HttpClient:
        return self

    def __exit__(
        self,
        exception_type: type[BaseException] | None,
        exception: BaseException | None,
        traceback: TracebackType | None,
    ) -> None:
        self._client.close()

    def request(
        self,
        method: str,
        url: str,
        *,
        headers: Mapping[str, str] | None = None,
        content: bytes | None = None,
    ) -> httpx.Response:
        try:
            return self._client.request(method, url, headers=headers, content=content)
        except httpx.RequestError as error:
            raise ProbeError(f"request failed for {redacted_url(url)}: {error}") from error

    def get(self, url: str) -> httpx.Response:
        return self.request("GET", url)

    def get_navigation(self, url: str) -> httpx.Response:
        return self.request(
            "GET",
            url,
            headers={
                "Accept": "text/html",
                "Sec-Fetch-Mode": "navigate",
                "Sec-Fetch-Dest": "document",
            },
        )

    def post_json(self, url: str, payload: Mapping[str, object]) -> httpx.Response:
        return self.request(
            "POST",
            url,
            headers={"Content-Type": "application/json", "Accept": "application/json"},
            content=json.dumps(payload, separators=(",", ":")).encode(),
        )

    def post_form(self, url: str, payload: Mapping[str, str]) -> httpx.Response:
        try:
            return self._client.post(
                url,
                data=payload,
                headers={
                    "Content-Type": "application/x-www-form-urlencoded",
                    "Accept": "*/*",
                },
            )
        except httpx.RequestError as error:
            raise ProbeError(f"request failed for {redacted_url(url)}: {error}") from error

    def has_cookie(self, name: str) -> bool:
        return any(cookie.name == name for cookie in self._client.cookies.jar)


def is_redirect(response: httpx.Response) -> bool:
    return response.status_code in (301, 302, 303, 307, 308) and "Location" in response.headers


def absolute_location(response: httpx.Response) -> str:
    location = response.headers.get("Location")
    if not location:
        raise ProbeError("redirect response did not include Location", response.status_code)
    return str(urljoin(str(response.url), location))


def extract_hidden_inputs(response: httpx.Response) -> dict[str, str]:
    parser = HiddenInputParser()
    parser.feed(response.text)
    return parser.hidden_inputs
