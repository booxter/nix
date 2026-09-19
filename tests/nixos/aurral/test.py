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
machine.wait_for_unit("aurral.service")
machine.wait_for_open_port(3001)

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

with subtest("service identities can access shared storage"):
    machine.succeed("runuser --user aurral -- touch /srv/media/library/flows/aurral")
    machine.succeed("touch /srv/media/library/music/aurral-source")
    machine.succeed("runuser --user aurral -- test -r /srv/media/library/music/aurral-source")
    service_pid = machine.succeed(
        "systemctl show --property MainPID --value aurral.service"
    ).strip()
    service_library = f"/proc/{service_pid}/root/srv/media/library/music"
    machine.succeed(command(["test", "-r", f"{service_library}/aurral-source"]))
    machine.fail(command(["touch", f"{service_library}/aurral-unexpected-write"]))
    machine.succeed("test -f /var/lib/aurral/aurral.db")

with subtest("configuration and state survive restart"):
    machine.succeed("systemctl restart aurral.service")
    machine.wait_for_unit("aurral.service")
    machine.wait_for_open_port(3001)
    assert request("/api/health/bootstrap")["onboardingRequired"] is False
    assert request("/api/auth/me", user="admin")["user"]["role"] == "admin"
