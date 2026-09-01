# ruff: noqa: F821
# NixOS test-driver globals and Nix-generated constants are prepended at evaluation.

import shlex
from typing import NamedTuple


class Response(NamedTuple):
    status: int
    headers: dict[str, str]
    body: str


def request(path, method="GET", headers=None, data=None):
    headers = headers or {}
    args = [
        "curl",
        "-sS",
        "-o",
        "/tmp/response-body",
        "-D",
        "/tmp/response-headers",
        "-w",
        "%{http_code}",
        "-X",
        method,
        "--cacert",
        f"{TEST_PKI}/ca.crt",
        "--resolve",
        f"{SERVER_NAME}:443:127.0.0.1",
    ]
    for name, value in headers.items():
        args += ["-H", f"{name}: {value}"]
    if data is not None:
        args += ["--data-binary", data]
    args.append(f"https://{SERVER_NAME}{path}")
    status = machine.succeed(" ".join(shlex.quote(arg) for arg in args)).strip()
    raw_headers = machine.succeed("cat /tmp/response-headers")
    body = machine.succeed("cat /tmp/response-body")
    parsed_headers = {}
    for line in raw_headers.splitlines():
        if ":" in line:
            name, value = line.split(":", 1)
            parsed_headers[name.lower()] = value.strip()
    return Response(int(status), parsed_headers, body)


def clear_logs():
    machine.succeed("truncate -s 0 /tmp/fake-oauth2-proxy.log /tmp/fake-oauth2-backend.log")


def logs():
    return (
        machine.succeed("cat /tmp/fake-oauth2-proxy.log"),
        machine.succeed("cat /tmp/fake-oauth2-backend.log"),
    )


def assert_reauth_401(response, htmx=False):
    assert response.status == 401, response
    assert response.headers.get("x-sso-reauth") == "1", response
    assert response.headers.get("cache-control") == "no-store", response
    assert "location" not in response.headers, response
    if htmx:
        assert response.headers.get("hx-refresh") == "true", response
    else:
        assert "hx-refresh" not in response.headers, response


start_all()
machine.wait_for_unit("nginx.service")
machine.wait_for_open_port(443)
machine.wait_for_open_port(4180)
machine.wait_for_open_port(9000)

with subtest("valid session reaches the backend"):
    response = request("/library", headers={"Cookie": "session=valid"})
    assert response.status == 200, response
    assert response.body == "GET /library user=test-user\n", response

with subtest("document navigation starts sign-in with a safe GET"):
    clear_logs()
    response = request(
        "/library?sort=new",
        headers={
            "Accept": "text/html",
            "Sec-Fetch-Mode": "navigate",
            "Sec-Fetch-Dest": "document",
        },
    )
    assert response.status == 302, response
    assert response.headers.get("location") == ("https://idp.example.invalid/authorize"), response
    oauth_log, backend_log = logs()
    assert "GET /oauth2/start body=0 " in oauth_log, oauth_log
    assert "redirect=https://test.example.invalid/library?sort=new" in oauth_log, oauth_log
    assert backend_log == "", backend_log

with subtest("HTML fallback works without Fetch Metadata"):
    response = request("/fallback", headers={"Accept": "text/html"})
    assert response.status == 302, response

with subtest("background fetch receives a marked 401"):
    clear_logs()
    response = request(
        "/api/items",
        headers={
            "Accept": "application/json",
            "Sec-Fetch-Mode": "cors",
            "Sec-Fetch-Dest": "empty",
        },
    )
    assert_reauth_401(response)
    oauth_log, backend_log = logs()
    assert "/oauth2/start" not in oauth_log, oauth_log
    assert backend_log == "", backend_log

with subtest("HTMX receives a refresh instruction"):
    response = request(
        "/fragment",
        headers={"Accept": "text/html", "HX-Request": "true"},
    )
    assert_reauth_401(response, htmx=True)

with subtest("unsafe methods are neither redirected nor replayed"):
    navigation_headers = {
        "Accept": "text/html",
        "Sec-Fetch-Mode": "navigate",
        "Sec-Fetch-Dest": "document",
    }
    for method in ["POST", "PUT", "PATCH", "DELETE"]:
        clear_logs()
        response = request(
            "/api/mutate",
            method=method,
            headers=navigation_headers,
            data=f"secret-{method}",
        )
        assert_reauth_401(response)
        oauth_log, backend_log = logs()
        assert "/oauth2/start" not in oauth_log, (method, oauth_log)
        assert "secret" not in oauth_log, (method, oauth_log)
        assert backend_log == "", (method, backend_log)

with subtest("non-document browser transports do not start sign-in"):
    transports = [
        {
            "Accept": "text/html",
            "Sec-Fetch-Mode": "navigate",
            "Sec-Fetch-Dest": "iframe",
        },
        {
            "Accept": "*/*",
            "Sec-Fetch-Mode": "no-cors",
            "Sec-Fetch-Dest": "script",
        },
        {
            "Accept": "text/event-stream",
            "Sec-Fetch-Mode": "cors",
            "Sec-Fetch-Dest": "empty",
        },
        {
            "Accept": "*/*",
            "Sec-Fetch-Mode": "websocket",
            "Sec-Fetch-Dest": "empty",
        },
    ]
    for headers in transports:
        assert_reauth_401(request("/transport", headers=headers))

with subtest("session probe reports valid and expired sessions"):
    valid = request("/oauth2/session", headers={"Cookie": "session=valid"})
    assert valid.status == 202, valid
    assert valid.headers.get("cache-control") == "no-store", valid
    assert "x-sso-reauth" not in valid.headers, valid
    assert_reauth_401(request("/oauth2/session"))

with subtest("only the proxy can emit the reauth marker"):
    spoofed = request("/spoof-marker", headers={"Cookie": "session=valid"})
    assert spoofed.status == 200, spoofed
    assert "x-sso-reauth" not in spoofed.headers, spoofed

    native = request("/native-401", headers={"Cookie": "session=valid"})
    assert native.status == 401, native
    assert "x-sso-reauth" not in native.headers, native
