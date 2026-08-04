from __future__ import annotations

import argparse
import base64
import hashlib
import secrets
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import TextIO, TypeVar
from urllib.parse import parse_qs, quote, urlencode, urljoin, urlsplit

import httpx
from pydantic import BaseModel, ValidationError

from .errors import ProbeError
from .http import (
    HttpClient,
    absolute_location,
    extract_hidden_inputs,
    is_redirect,
)
from .metrics import ProbeMetrics
from .models import AuthResponse, Discovery, JWKS, TokenResponse, UserInfo
from .state import read_password, read_state, write_metrics, write_state


Model = TypeVar("Model", bound=BaseModel)


@dataclass(frozen=True)
class Config:
    idp_url: str
    username: str
    password_file: Path
    client_id: str
    redirect_uri: str
    searxng_url: str
    metrics_file: Path
    state_file: Path | None = None
    scope: str = "openid email profile"
    timeout: float = 10.0


def log(message: str, output: TextIO) -> None:
    print(f"oidc-synthetic-probe: {message}", file=output)


def url_join(base: str, path: str) -> str:
    return urljoin(base.rstrip("/") + "/", path.lstrip("/"))


def parse_response(response: httpx.Response, context: str, model: type[Model]) -> Model:
    if response.status_code != 200:
        raise ProbeError(f"{context} returned HTTP {response.status_code}", response.status_code)
    try:
        return model.model_validate_json(response.content)
    except ValidationError as error:
        raise ProbeError(f"{context} returned invalid data", response.status_code) from error


def require_auth_state(response: AuthResponse, variant: str, context: str) -> object:
    value = response.state.variant(variant)
    if value is None:
        raise ProbeError(f"{context} did not return auth state '{variant}'")
    return value


def oidc_redirect_matches(location: str, redirect_uri: str) -> bool:
    current = urlsplit(location)
    expected = urlsplit(redirect_uri)
    return (current.scheme, current.netloc, current.path) == (
        expected.scheme,
        expected.netloc,
        expected.path,
    )


def parse_authorization_code(location: str, redirect_uri: str, expected_state: str) -> str:
    if not oidc_redirect_matches(location, redirect_uri):
        raise ProbeError("authorization redirect did not target the configured redirect URI")
    query = parse_qs(urlsplit(location).query)
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
    payload = parse_response(response, "Kanidm auth init", AuthResponse)
    choices = require_auth_state(payload, "choose", "Kanidm auth init")
    if isinstance(choices, list) and "password" not in choices:
        raise ProbeError("Kanidm auth did not offer password auth", response.status_code)

    response = client.post_json(auth_url, {"step": {"begin": "password"}})
    payload = parse_response(response, "Kanidm auth begin", AuthResponse)
    allowed = require_auth_state(payload, "continue", "Kanidm auth begin")
    if isinstance(allowed, list) and "password" not in allowed:
        raise ProbeError("Kanidm auth did not request a password credential", response.status_code)

    response = client.post_json(auth_url, {"step": {"cred": {"password": password}}})
    payload = parse_response(response, "Kanidm auth password", AuthResponse)
    require_auth_state(payload, "success", "Kanidm auth password")
    if not client.has_cookie("bearer"):
        raise ProbeError(
            "Kanidm auth succeeded without setting a bearer cookie",
            response.status_code,
        )
    return response.status_code


def follow_oidc_authorization(
    client: HttpClient,
    idp_url: str,
    initial_response: httpx.Response,
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
                ), response.status_code
            response = client.get_navigation(location)
            continue
        if response.status_code == 200:
            hidden_inputs = extract_hidden_inputs(response)
            if "consent_token" not in hidden_inputs:
                raise ProbeError(
                    "authorization returned an HTML page without consent",
                    response.status_code,
                )
            response = client.post_form(consent_url, hidden_inputs)
            continue
        raise ProbeError(
            f"authorization returned HTTP {response.status_code}",
            response.status_code,
        )
    raise ProbeError("authorization redirect loop exceeded")


def run_kanidm_probe(
    client: HttpClient,
    metrics: ProbeMetrics,
    config: Config,
    password: str,
    errors: TextIO,
) -> bool:
    probe = "kanidm"
    started_at = metrics.started()
    ok = False
    try:
        discovery_url = url_join(
            config.idp_url,
            f"/oauth2/openid/{quote(config.client_id)}/.well-known/openid-configuration",
        )
        response = client.get(discovery_url)
        discovery = parse_response(response, "OIDC discovery", Discovery)
        metrics.record_phase(probe, "discovery", True, response.status_code)

        jwks_uri = discovery.jwks_uri or url_join(
            config.idp_url,
            f"/oauth2/openid/{quote(config.client_id)}/public_key.jwk",
        )
        response = client.get(jwks_uri)
        parse_response(response, "OIDC JWKS", JWKS)
        metrics.record_phase(probe, "jwks", True, response.status_code)

        status = kanidm_cookie_login(client, config.idp_url, config.username, password)
        metrics.record_phase(probe, "auth", True, status)

        verifier, challenge = pkce_pair()
        state = secrets.token_urlsafe(32)
        authorization_endpoint = discovery.authorization_endpoint or url_join(
            config.idp_url, "/ui/oauth2"
        )
        query = urlencode(
            {
                "response_type": "code",
                "client_id": config.client_id,
                "redirect_uri": config.redirect_uri,
                "scope": config.scope,
                "state": state,
                "nonce": secrets.token_urlsafe(32),
                "code_challenge": challenge,
                "code_challenge_method": "S256",
            }
        )
        response = client.get_navigation(f"{authorization_endpoint}?{query}")
        code, status = follow_oidc_authorization(
            client, config.idp_url, response, config.redirect_uri, state
        )
        metrics.record_phase(probe, "authorize", True, status)

        token_endpoint = discovery.token_endpoint or url_join(config.idp_url, "/oauth2/token")
        response = client.post_form(
            token_endpoint,
            {
                "grant_type": "authorization_code",
                "client_id": config.client_id,
                "redirect_uri": config.redirect_uri,
                "code": code,
                "code_verifier": verifier,
            },
        )
        token = parse_response(response, "OIDC token exchange", TokenResponse)
        metrics.record_phase(probe, "token", True, response.status_code)

        userinfo_endpoint = discovery.userinfo_endpoint or url_join(
            config.idp_url,
            f"/oauth2/openid/{quote(config.client_id)}/userinfo",
        )
        response = client.request(
            "GET",
            userinfo_endpoint,
            headers={"Authorization": f"Bearer {token.access_token}", "Accept": "application/json"},
        )
        parse_response(response, "OIDC userinfo", UserInfo)
        metrics.record_phase(probe, "userinfo", True, response.status_code)
        ok = True
        return True
    except ProbeError as error:
        log(f"{probe} failed: {error}", errors)
        return False
    finally:
        metrics.finish_probe(probe, ok, started_at)


def final_searxng_response(response: httpx.Response, searxng_url: str) -> bool:
    target = urlsplit(searxng_url)
    current = urlsplit(str(response.url))
    return (
        response.status_code == 200
        and current.scheme == target.scheme
        and current.netloc == target.netloc
        and not current.path.startswith("/oauth2/")
    )


def run_searxng_probe(
    client: HttpClient,
    metrics: ProbeMetrics,
    config: Config,
    logged_in: bool,
    errors: TextIO,
) -> bool:
    probe = "searxng"
    started_at = metrics.started()
    ok = False
    last_status = 0
    metrics.record_phase(probe, "auth", logged_in, 200 if logged_in else 0)
    if not logged_in:
        metrics.finish_probe(probe, False, started_at)
        return False
    try:
        response = client.get_navigation(config.searxng_url)
        last_status = response.status_code
        consent_url = url_join(config.idp_url, "/ui/oauth2/consent")
        for _ in range(30):
            if final_searxng_response(response, config.searxng_url):
                metrics.record_phase(probe, "proxy", True, response.status_code)
                ok = True
                return True
            if is_redirect(response):
                response = client.get_navigation(absolute_location(response))
                last_status = response.status_code
                continue
            if response.status_code == 200:
                hidden_inputs = extract_hidden_inputs(response)
                if "consent_token" in hidden_inputs:
                    response = client.post_form(consent_url, hidden_inputs)
                    last_status = response.status_code
                    continue
            raise ProbeError(
                f"search proxy flow returned HTTP {response.status_code}",
                response.status_code,
            )
        raise ProbeError("search proxy redirect loop exceeded", last_status)
    except ProbeError as error:
        metrics.record_phase(probe, "proxy", False, error.status or last_status)
        log(f"{probe} failed: {error}", errors)
        return False
    finally:
        metrics.finish_probe(probe, ok, started_at)


def run(config: Config, errors: TextIO = sys.stderr) -> int:
    metrics = ProbeMetrics()
    now = int(time.time())
    state = read_state(config.state_file)
    try:
        password = read_password(config.password_file)
    except OSError as error:
        log(f"failed to read password file: {error}", errors)
        metrics.finalize(state, now)
        write_metrics(config.metrics_file, metrics.render())
        return 0

    with HttpClient(config.timeout) as client:
        logged_in = run_kanidm_probe(client, metrics, config, password, errors)
        run_searxng_probe(client, metrics, config, logged_in, errors)
    metrics.finalize(state, now)
    write_state(config.state_file, state)
    write_metrics(config.metrics_file, metrics.render())
    return 0


def parse_args(arguments: list[str] | None = None) -> Config:
    parser = argparse.ArgumentParser(description="Run synthetic OIDC and oauth2-proxy probes.")
    parser.add_argument("--idp-url", required=True)
    parser.add_argument("--username", required=True)
    parser.add_argument("--password-file", required=True, type=Path)
    parser.add_argument("--client-id", required=True)
    parser.add_argument("--redirect-uri", required=True)
    parser.add_argument("--searxng-url", required=True)
    parser.add_argument("--metrics-file", required=True, type=Path)
    parser.add_argument("--state-file", type=Path)
    parser.add_argument("--scope", default="openid email profile")
    parser.add_argument("--timeout", type=float, default=10.0)
    namespace = parser.parse_args(arguments)
    if namespace.timeout <= 0:
        parser.error("--timeout must be positive")
    return Config(
        idp_url=namespace.idp_url,
        username=namespace.username,
        password_file=namespace.password_file,
        client_id=namespace.client_id,
        redirect_uri=namespace.redirect_uri,
        searxng_url=namespace.searxng_url,
        metrics_file=namespace.metrics_file,
        state_file=namespace.state_file,
        scope=namespace.scope,
        timeout=namespace.timeout,
    )


def main() -> int:
    return run(parse_args())
