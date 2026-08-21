# ruff: noqa: F821
# NixOS test-driver globals and Nix-generated constants are prepended at evaluation.

import json
import shlex


def command(arguments):
    return " ".join(shlex.quote(str(argument)) for argument in arguments)


def request(path, *, data=None, user=None):
    arguments = [CURL, "--silent", "--show-error", "--fail-with-body"]
    if user is not None:
        arguments += ["--header", f"x-forwarded-user: {user}"]
    if data is not None:
        arguments += [
            "--header",
            "content-type: application/json",
            "--data",
            json.dumps(data),
        ]
    arguments.append(f"{AURRAL_URL}{path}")
    return json.loads(machine.succeed(command(arguments)))


def status(path, *, data=None, user=None):
    arguments = [
        CURL,
        "--silent",
        "--output",
        "/dev/null",
        "--write-out",
        "%{http_code}",
    ]
    if user is not None:
        arguments += ["--header", f"x-forwarded-user: {user}"]
    if data is not None:
        arguments += [
            "--header",
            "content-type: application/json",
            "--data",
            json.dumps(data),
        ]
    arguments.append(f"{AURRAL_URL}{path}")
    return int(machine.succeed(command(arguments)))


start_all()
machine.wait_for_unit("fake-lidarr.service")
machine.wait_for_unit("wg.service")
machine.wait_for_unit("vpn-wg-bridge-access.service")
machine.wait_for_unit("slskd.service")
machine.wait_for_unit("aurral.service")
machine.wait_for_open_port(3001)
machine.wait_until_succeeds(
    command(
        [
            CURL,
            "--fail",
            "--silent",
            "--header",
            f"X-API-KEY: {SLSKD_API_KEY}",
            f"{SLSKD_URL}/api/v0/application",
        ]
    )
)

with subtest("serves the application and reports a live backend"):
    assert request("/api/health/live")["status"] == "ok"
    machine.succeed(command([CURL, "--fail", "--silent", f"{AURRAL_URL}/"]))

with subtest("completes onboarding against Lidarr"):
    bootstrap = request("/api/health/bootstrap")
    assert bootstrap["onboardingRequired"] is True
    assert bootstrap["proxyAuthEnabled"] is True
    assert request(
        "/api/onboarding/complete",
        data={
            "lidarr": {"url": LIDARR_URL, "apiKey": LIDARR_API_KEY},
            "security": {"localNetworkBypass": {"enabled": False}},
        },
    ) == {"success": True}
    assert request("/api/health/bootstrap")["onboardingRequired"] is False

with subtest("maps trusted proxy users to configured roles"):
    assert status("/api/auth/me") == 401
    admin = request("/api/auth/me", user="admin")["user"]
    listener = request("/api/auth/me", user="listener")["user"]
    assert (admin["username"], admin["role"]) == ("admin", "admin")
    assert (listener["username"], listener["role"]) == ("listener", "user")

with subtest("rejects local password authentication"):
    assert (
        status(
            "/api/auth/login",
            data={"username": "admin", "password": "test-password"},
        )
        == 403
    )

with subtest("uses the managed slskd connection"):
    result = request("/api/settings/slskd/test", data={}, user="admin")
    assert result["success"] is True
    assert result["configured"] is True
    assert result["ok"] is True
    assert result["warning"] is True

with subtest("service identities can access shared storage"):
    machine.succeed("runuser --user aurral -- touch /srv/media/library/flows/aurral")
    machine.succeed("runuser --user slskd -- touch /srv/media/slskd/complete/slskd")
    machine.succeed("runuser --user aurral -- test -r /srv/media/slskd/complete/slskd")
    machine.succeed("test -f /var/lib/aurral/aurral.db")

with subtest("configuration and state survive restart"):
    machine.succeed("systemctl restart aurral.service")
    machine.wait_for_unit("aurral.service")
    machine.wait_for_open_port(3001)
    assert request("/api/health/bootstrap")["onboardingRequired"] is False
    assert request("/api/auth/me", user="admin")["user"]["role"] == "admin"
