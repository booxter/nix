#!/usr/bin/env python3

from __future__ import annotations

import argparse
import base64
import contextlib
import hashlib
import html
import json
import os
import secrets
import socket
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from html.parser import HTMLParser
from http.cookiejar import CookieJar
from typing import Any


EXPECTED_PHASES = {
    "kanidm": [
        "discovery",
        "jwks",
        "auth",
        "authorize",
        "token",
        "userinfo",
    ],
    "searxng": [
        "auth",
        "proxy",
    ],
}


class ProbeError(Exception):
    def __init__(self, message: str, status: int = 0):
        super().__init__(message)
        self.status = status


@dataclass
class HttpResponse:
    status: int
    headers: Any
    body: bytes
    url: str


class NoRedirectHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):  # noqa: D401
        return None


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
        name = fields.get("name")
        if name:
            self.hidden_inputs[name] = html.unescape(fields.get("value", ""))


def redacted_url(url: str) -> str:
    parts = urllib.parse.urlsplit(url)
    return urllib.parse.urlunsplit((parts.scheme, parts.netloc, parts.path, "", ""))


class HttpClient:
    def __init__(self, timeout: float) -> None:
        self.timeout = timeout
        self.cookie_jar = CookieJar()
        self.opener = urllib.request.build_opener(
            urllib.request.HTTPCookieProcessor(self.cookie_jar),
            NoRedirectHandler,
        )

    def request(
        self,
        method: str,
        url: str,
        headers: dict[str, str] | None = None,
        body: bytes | None = None,
    ) -> HttpResponse:
        request_headers = {
            "User-Agent": "oidc-synthetic-probe/1.0",
            "Accept": "*/*",
        }
        if headers:
            request_headers.update(headers)

        request = urllib.request.Request(
            url,
            data=body,
            headers=request_headers,
            method=method,
        )

        try:
            with self.opener.open(request, timeout=self.timeout) as response:
                return HttpResponse(
                    status=response.status,
                    headers=response.headers,
                    body=response.read(),
                    url=response.geturl(),
                )
        except urllib.error.HTTPError as error:
            return HttpResponse(
                status=error.code,
                headers=error.headers,
                body=error.read(),
                url=error.geturl(),
            )
        except (urllib.error.URLError, TimeoutError, socket.timeout) as error:
            raise ProbeError(
                f"request failed for {redacted_url(url)}: {error}"
            ) from error

    def get(self, url: str) -> HttpResponse:
        return self.request("GET", url)

    def post_json(self, url: str, payload: dict[str, Any]) -> HttpResponse:
        body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        return self.request(
            "POST",
            url,
            headers={
                "Content-Type": "application/json",
                "Accept": "application/json",
            },
            body=body,
        )

    def post_form(self, url: str, payload: dict[str, str]) -> HttpResponse:
        body = urllib.parse.urlencode(payload).encode("utf-8")
        return self.request(
            "POST",
            url,
            headers={
                "Content-Type": "application/x-www-form-urlencoded",
                "Accept": "*/*",
            },
            body=body,
        )

    def has_cookie(self, name: str) -> bool:
        return any(cookie.name == name for cookie in self.cookie_jar)


@dataclass
class ProbeMetrics:
    phase_ok: dict[tuple[str, str], int]
    phase_status: dict[tuple[str, str], int]
    probe_ok: dict[str, int]
    probe_duration: dict[str, float]
    probe_last_success: dict[str, int]

    @classmethod
    def create(cls) -> "ProbeMetrics":
        phase_ok: dict[tuple[str, str], int] = {}
        phase_status: dict[tuple[str, str], int] = {}
        for probe, phases in EXPECTED_PHASES.items():
            for phase in phases:
                key = (probe, phase)
                phase_ok[key] = 0
                phase_status[key] = 0
        return cls(
            phase_ok=phase_ok,
            phase_status=phase_status,
            probe_ok={probe: 0 for probe in EXPECTED_PHASES},
            probe_duration={probe: 0.0 for probe in EXPECTED_PHASES},
            probe_last_success={probe: 0 for probe in EXPECTED_PHASES},
        )

    def record_phase(self, probe: str, phase: str, ok: bool, status: int = 0) -> None:
        key = (probe, phase)
        self.phase_ok[key] = 1 if ok else 0
        self.phase_status[key] = status

    def finish_probe(self, probe: str, ok: bool, started_at: float) -> None:
        self.probe_ok[probe] = 1 if ok else 0
        self.probe_duration[probe] = max(0.0, time.monotonic() - started_at)


def log(message: str) -> None:
    print(f"oidc-synthetic-probe: {message}", file=sys.stderr)


def url_join(base: str, path: str) -> str:
    return urllib.parse.urljoin(base.rstrip("/") + "/", path.lstrip("/"))


def is_redirect(response: HttpResponse) -> bool:
    return response.status in (301, 302, 303, 307, 308) and bool(
        response.headers.get("Location")
    )


def absolute_location(response: HttpResponse) -> str:
    location = response.headers.get("Location")
    if not location:
        raise ProbeError("redirect response did not include Location", response.status)
    return urllib.parse.urljoin(response.url, location)


def parse_json_response(response: HttpResponse, context: str) -> dict[str, Any]:
    if response.status != 200:
        raise ProbeError(f"{context} returned HTTP {response.status}", response.status)
    try:
        decoded = response.body.decode("utf-8")
        payload = json.loads(decoded)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ProbeError(f"{context} returned invalid JSON", response.status) from error
    if not isinstance(payload, dict):
        raise ProbeError(f"{context} returned non-object JSON", response.status)
    return payload


def auth_state(payload: dict[str, Any], variant: str) -> Any | None:
    state = payload.get("state")
    if not isinstance(state, dict):
        return None
    return state.get(variant)


def require_state(payload: dict[str, Any], variant: str, context: str) -> Any:
    value = auth_state(payload, variant)
    if value is None:
        raise ProbeError(f"{context} did not return auth state '{variant}'")
    return value


def oidc_redirect_matches(location: str, redirect_uri: str) -> bool:
    location_parts = urllib.parse.urlsplit(location)
    redirect_parts = urllib.parse.urlsplit(redirect_uri)
    return (
        location_parts.scheme == redirect_parts.scheme
        and location_parts.netloc == redirect_parts.netloc
        and location_parts.path == redirect_parts.path
    )


def extract_hidden_inputs(response: HttpResponse) -> dict[str, str]:
    parser = HiddenInputParser()
    with contextlib.suppress(UnicodeDecodeError):
        parser.feed(response.body.decode("utf-8"))
    return parser.hidden_inputs


def parse_authorization_code(
    location: str, redirect_uri: str, expected_state: str
) -> str:
    if not oidc_redirect_matches(location, redirect_uri):
        raise ProbeError(
            "authorization redirect did not target the configured redirect URI"
        )

    query = urllib.parse.parse_qs(urllib.parse.urlsplit(location).query)
    if query.get("state", [""])[0] != expected_state:
        raise ProbeError("authorization response state did not match")
    if "error" in query:
        raise ProbeError(f"authorization endpoint returned error: {query['error'][0]}")
    code = query.get("code", [""])[0]
    if not code:
        raise ProbeError("authorization response did not include a code")
    return code


def pkce_pair() -> tuple[str, str]:
    verifier = secrets.token_urlsafe(64)
    digest = hashlib.sha256(verifier.encode("ascii")).digest()
    challenge = base64.urlsafe_b64encode(digest).decode("ascii").rstrip("=")
    return verifier, challenge


def kanidm_cookie_login(
    client: HttpClient,
    idp_url: str,
    username: str,
    password: str,
) -> int:
    auth_url = url_join(idp_url, "/v1/auth")

    response = client.post_json(
        auth_url,
        {
            "step": {
                "init2": {
                    "username": username,
                    "issue": "cookie",
                    "privileged": False,
                }
            }
        },
    )
    payload = parse_json_response(response, "Kanidm auth init")
    choices = require_state(payload, "choose", "Kanidm auth init")
    if isinstance(choices, list) and "password" not in choices:
        raise ProbeError("Kanidm auth did not offer password auth", response.status)

    response = client.post_json(auth_url, {"step": {"begin": "password"}})
    payload = parse_json_response(response, "Kanidm auth begin")
    allowed = require_state(payload, "continue", "Kanidm auth begin")
    if isinstance(allowed, list) and "password" not in allowed:
        raise ProbeError(
            "Kanidm auth did not request a password credential", response.status
        )

    response = client.post_json(auth_url, {"step": {"cred": {"password": password}}})
    payload = parse_json_response(response, "Kanidm auth password")
    require_state(payload, "success", "Kanidm auth password")
    if not client.has_cookie("bearer"):
        raise ProbeError(
            "Kanidm auth succeeded without setting a bearer cookie", response.status
        )
    return response.status


def follow_oidc_authorization(
    client: HttpClient,
    idp_url: str,
    initial_response: HttpResponse,
    redirect_uri: str,
    expected_state: str,
) -> tuple[str, int]:
    response = initial_response
    consent_url = url_join(idp_url, "/ui/oauth2/consent")

    for _ in range(20):
        if is_redirect(response):
            location = absolute_location(response)
            if oidc_redirect_matches(location, redirect_uri):
                return parse_authorization_code(
                    location, redirect_uri, expected_state
                ), response.status
            response = client.get(location)
            continue

        if response.status == 200:
            hidden_inputs = extract_hidden_inputs(response)
            if "consent_token" not in hidden_inputs:
                raise ProbeError(
                    "authorization returned an HTML page without consent",
                    response.status,
                )
            response = client.post_form(consent_url, hidden_inputs)
            continue

        raise ProbeError(
            f"authorization returned HTTP {response.status}", response.status
        )

    raise ProbeError("authorization redirect loop exceeded")


def run_kanidm_probe(
    client: HttpClient,
    metrics: ProbeMetrics,
    idp_url: str,
    username: str,
    password: str,
    client_id: str,
    redirect_uri: str,
    scope: str,
) -> bool:
    probe = "kanidm"
    started_at = time.monotonic()
    ok = False

    try:
        discovery_url = url_join(
            idp_url,
            f"/oauth2/openid/{urllib.parse.quote(client_id)}/.well-known/openid-configuration",
        )
        response = client.get(discovery_url)
        discovery = parse_json_response(response, "OIDC discovery")
        metrics.record_phase(probe, "discovery", True, response.status)

        jwks_uri = discovery.get("jwks_uri") or url_join(
            idp_url,
            f"/oauth2/openid/{urllib.parse.quote(client_id)}/public_key.jwk",
        )
        response = client.get(str(jwks_uri))
        jwks = parse_json_response(response, "OIDC JWKS")
        if not isinstance(jwks.get("keys"), list) or not jwks["keys"]:
            raise ProbeError("OIDC JWKS did not include keys", response.status)
        metrics.record_phase(probe, "jwks", True, response.status)

        status = kanidm_cookie_login(client, idp_url, username, password)
        metrics.record_phase(probe, "auth", True, status)

        verifier, challenge = pkce_pair()
        state = secrets.token_urlsafe(32)
        nonce = secrets.token_urlsafe(32)
        authorization_endpoint = str(
            discovery.get("authorization_endpoint") or url_join(idp_url, "/ui/oauth2")
        )
        auth_query = urllib.parse.urlencode(
            {
                "response_type": "code",
                "client_id": client_id,
                "redirect_uri": redirect_uri,
                "scope": scope,
                "state": state,
                "nonce": nonce,
                "code_challenge": challenge,
                "code_challenge_method": "S256",
            }
        )
        response = client.get(f"{authorization_endpoint}?{auth_query}")
        code, status = follow_oidc_authorization(
            client, idp_url, response, redirect_uri, state
        )
        metrics.record_phase(probe, "authorize", True, status)

        token_endpoint = str(
            discovery.get("token_endpoint") or url_join(idp_url, "/oauth2/token")
        )
        response = client.post_form(
            token_endpoint,
            {
                "grant_type": "authorization_code",
                "client_id": client_id,
                "redirect_uri": redirect_uri,
                "code": code,
                "code_verifier": verifier,
            },
        )
        token_payload = parse_json_response(response, "OIDC token exchange")
        access_token = token_payload.get("access_token")
        if not isinstance(access_token, str) or not access_token:
            raise ProbeError(
                "OIDC token response did not include an access token", response.status
            )
        metrics.record_phase(probe, "token", True, response.status)

        userinfo_endpoint = str(
            discovery.get("userinfo_endpoint")
            or url_join(
                idp_url, f"/oauth2/openid/{urllib.parse.quote(client_id)}/userinfo"
            )
        )
        response = client.request(
            "GET",
            userinfo_endpoint,
            headers={
                "Authorization": f"Bearer {access_token}",
                "Accept": "application/json",
            },
        )
        userinfo = parse_json_response(response, "OIDC userinfo")
        if not isinstance(userinfo.get("sub"), str) or not userinfo["sub"]:
            raise ProbeError("OIDC userinfo did not include a subject", response.status)
        metrics.record_phase(probe, "userinfo", True, response.status)

        ok = True
        return True
    except ProbeError as error:
        log(f"{probe} failed: {error}")
        return False
    finally:
        metrics.finish_probe(probe, ok, started_at)


def final_searxng_response(response: HttpResponse, searxng_url: str) -> bool:
    target = urllib.parse.urlsplit(searxng_url)
    current = urllib.parse.urlsplit(response.url)
    return (
        response.status == 200
        and current.scheme == target.scheme
        and current.netloc == target.netloc
        and not current.path.startswith("/oauth2/")
    )


def run_searxng_probe(
    client: HttpClient,
    metrics: ProbeMetrics,
    idp_url: str,
    searxng_url: str,
    logged_in: bool,
) -> bool:
    probe = "searxng"
    started_at = time.monotonic()
    ok = False
    last_status = 0

    metrics.record_phase(probe, "auth", logged_in, 200 if logged_in else 0)
    if not logged_in:
        metrics.finish_probe(probe, False, started_at)
        return False

    try:
        response = client.get(searxng_url)
        last_status = response.status
        consent_url = url_join(idp_url, "/ui/oauth2/consent")

        for _ in range(30):
            if final_searxng_response(response, searxng_url):
                metrics.record_phase(probe, "proxy", True, response.status)
                ok = True
                return True

            if is_redirect(response):
                response = client.get(absolute_location(response))
                last_status = response.status
                continue

            if response.status == 200:
                hidden_inputs = extract_hidden_inputs(response)
                if "consent_token" in hidden_inputs:
                    response = client.post_form(consent_url, hidden_inputs)
                    last_status = response.status
                    continue

            raise ProbeError(
                f"search proxy flow returned HTTP {response.status}", response.status
            )

        raise ProbeError("search proxy redirect loop exceeded", last_status)
    except ProbeError as error:
        metrics.record_phase(probe, "proxy", False, error.status or last_status)
        log(f"{probe} failed: {error}")
        return False
    finally:
        metrics.finish_probe(probe, ok, started_at)


def read_state(path: str | None) -> dict[str, Any]:
    if not path:
        return {}
    try:
        with open(path, "r", encoding="utf-8") as handle:
            payload = json.load(handle)
    except FileNotFoundError:
        return {}
    except (OSError, json.JSONDecodeError):
        return {}
    return payload if isinstance(payload, dict) else {}


def write_state(path: str | None, state: dict[str, Any]) -> None:
    if not path:
        return
    directory = os.path.dirname(path)
    os.makedirs(directory, exist_ok=True)
    fd, tmp_path = tempfile.mkstemp(
        prefix=".oidc-synthetic-probe-state.", dir=directory
    )
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(state, handle, sort_keys=True)
            handle.write("\n")
        os.replace(tmp_path, path)
    finally:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(tmp_path)


def update_last_success(metrics: ProbeMetrics, state: dict[str, Any], now: int) -> None:
    probes = state.setdefault("probes", {})
    if not isinstance(probes, dict):
        probes = {}
        state["probes"] = probes

    for probe in EXPECTED_PHASES:
        probe_state = probes.setdefault(probe, {})
        if not isinstance(probe_state, dict):
            probe_state = {}
            probes[probe] = probe_state
        if metrics.probe_ok[probe]:
            probe_state["last_success"] = now
        metrics.probe_last_success[probe] = int(probe_state.get("last_success") or 0)


def prom_label_value(value: str) -> str:
    return value.replace("\\", "\\\\").replace("\n", "\\n").replace('"', '\\"')


def prom_line(name: str, labels: dict[str, str], value: int | float | str) -> str:
    rendered_labels = ",".join(
        f'{key}="{prom_label_value(val)}"' for key, val in sorted(labels.items())
    )
    if rendered_labels:
        return f"{name}{{{rendered_labels}}} {value}"
    return f"{name} {value}"


def render_metrics(metrics: ProbeMetrics, now: int) -> str:
    lines = [
        "# HELP host_observability_oidc_synthetic_probe_ok Whether the most recent OIDC synthetic probe succeeded.",
        "# TYPE host_observability_oidc_synthetic_probe_ok gauge",
    ]
    for probe in sorted(EXPECTED_PHASES):
        lines.append(
            prom_line(
                "host_observability_oidc_synthetic_probe_ok",
                {"probe": probe},
                metrics.probe_ok[probe],
            )
        )

    lines.extend(
        [
            "# HELP host_observability_oidc_synthetic_probe_phase_ok Whether the most recent OIDC synthetic probe phase succeeded.",
            "# TYPE host_observability_oidc_synthetic_probe_phase_ok gauge",
        ]
    )
    for probe, phases in sorted(EXPECTED_PHASES.items()):
        for phase in phases:
            lines.append(
                prom_line(
                    "host_observability_oidc_synthetic_probe_phase_ok",
                    {"probe": probe, "phase": phase},
                    metrics.phase_ok[(probe, phase)],
                )
            )

    lines.extend(
        [
            "# HELP host_observability_oidc_synthetic_probe_http_status_code HTTP status code observed by the most recent OIDC synthetic probe phase.",
            "# TYPE host_observability_oidc_synthetic_probe_http_status_code gauge",
        ]
    )
    for probe, phases in sorted(EXPECTED_PHASES.items()):
        for phase in phases:
            lines.append(
                prom_line(
                    "host_observability_oidc_synthetic_probe_http_status_code",
                    {"probe": probe, "phase": phase},
                    metrics.phase_status[(probe, phase)],
                )
            )

    lines.extend(
        [
            "# HELP host_observability_oidc_synthetic_probe_duration_seconds Duration of the most recent OIDC synthetic probe.",
            "# TYPE host_observability_oidc_synthetic_probe_duration_seconds gauge",
        ]
    )
    for probe in sorted(EXPECTED_PHASES):
        lines.append(
            prom_line(
                "host_observability_oidc_synthetic_probe_duration_seconds",
                {"probe": probe},
                f"{metrics.probe_duration[probe]:.6f}",
            )
        )

    lines.extend(
        [
            "# HELP host_observability_oidc_synthetic_probe_last_run_timestamp_seconds Unix timestamp of the most recent OIDC synthetic probe run.",
            "# TYPE host_observability_oidc_synthetic_probe_last_run_timestamp_seconds gauge",
        ]
    )
    for probe in sorted(EXPECTED_PHASES):
        lines.append(
            prom_line(
                "host_observability_oidc_synthetic_probe_last_run_timestamp_seconds",
                {"probe": probe},
                now,
            )
        )

    lines.extend(
        [
            "# HELP host_observability_oidc_synthetic_probe_last_success_timestamp_seconds Unix timestamp of the most recent successful OIDC synthetic probe run.",
            "# TYPE host_observability_oidc_synthetic_probe_last_success_timestamp_seconds gauge",
        ]
    )
    for probe in sorted(EXPECTED_PHASES):
        lines.append(
            prom_line(
                "host_observability_oidc_synthetic_probe_last_success_timestamp_seconds",
                {"probe": probe},
                metrics.probe_last_success[probe],
            )
        )

    return "\n".join(lines) + "\n"


def write_metrics(path: str, content: str) -> None:
    directory = os.path.dirname(path)
    os.makedirs(directory, exist_ok=True)
    fd, tmp_path = tempfile.mkstemp(prefix=".oidc-synthetic-probe.", dir=directory)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(content)
        os.chmod(tmp_path, 0o644)
        os.replace(tmp_path, path)
    finally:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(tmp_path)


def read_password(path: str) -> str:
    with open(path, "r", encoding="utf-8") as handle:
        return handle.read().rstrip("\n")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run synthetic OIDC and oauth2-proxy probes."
    )
    parser.add_argument("--idp-url", required=True)
    parser.add_argument("--username", required=True)
    parser.add_argument("--password-file", required=True)
    parser.add_argument("--client-id", required=True)
    parser.add_argument("--redirect-uri", required=True)
    parser.add_argument("--searxng-url", required=True)
    parser.add_argument("--metrics-file", required=True)
    parser.add_argument("--state-file")
    parser.add_argument("--scope", default="openid email profile")
    parser.add_argument("--timeout", type=float, default=10.0)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    metrics = ProbeMetrics.create()
    now = int(time.time())
    state = read_state(args.state_file)

    try:
        password = read_password(args.password_file)
    except OSError as error:
        log(f"failed to read password file: {error}")
        update_last_success(metrics, state, now)
        write_metrics(args.metrics_file, render_metrics(metrics, now))
        return 0

    client = HttpClient(timeout=args.timeout)
    logged_in = run_kanidm_probe(
        client=client,
        metrics=metrics,
        idp_url=args.idp_url,
        username=args.username,
        password=password,
        client_id=args.client_id,
        redirect_uri=args.redirect_uri,
        scope=args.scope,
    )
    run_searxng_probe(
        client=client,
        metrics=metrics,
        idp_url=args.idp_url,
        searxng_url=args.searxng_url,
        logged_in=logged_in,
    )

    update_last_success(metrics, state, now)
    write_state(args.state_file, state)
    write_metrics(args.metrics_file, render_metrics(metrics, now))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
