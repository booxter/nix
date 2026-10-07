# ruff: noqa: F821
# NixOS test-driver globals and Nix-generated constants are prepended at evaluation.

import json
import shlex


def request(path, arguments="--fail"):
    return machine.succeed(
        f"{CURL} --silent --show-error --cacert {CA_CERTIFICATE} "
        f"--resolve {SERVER_NAME}:443:127.0.0.1 {arguments} "
        f"https://{SERVER_NAME}{path}"
    )


def heartbeat():
    machine.wait_until_succeeds(
        f"{CURL} --fail --show-error --cacert {CA_CERTIFICATE} "
        f"--resolve {SERVER_NAME}:443:127.0.0.1 "
        f"https://{SERVER_NAME}/api/heartbeat"
    )
    return json.loads(request("/api/heartbeat"))


start_all()

with subtest("the complete service graph starts"):
    for unit in (
        "mysql.service",
        "romm-valkey.service",
        "romm.service",
        "romm-scheduler.service",
        "romm-worker.service",
        "romm-watcher.service",
        "nginx.service",
    ):
        machine.wait_for_unit(unit)
    for unit in ("romm-db-init.service", "romm-backup.service"):
        machine.succeed(f"systemctl show --property=Result --value {unit} | grep -Fx success")

with subtest("the HTTPS frontend reaches the RomM API"):
    machine.wait_for_open_port(443)
    status = heartbeat()
    assert status["OIDC"]["ENABLED"]
    assert status["FRONTEND"]["DISABLE_USERPASS_LOGIN"]
    assert "romm" in request("/").lower()
    assert (
        request("/assets/platforms/default.ico", "--fail -o /dev/null -w '%{content_type}'")
        != "text/html"
    )

with subtest("private resources and internal download paths are protected"):
    machine.succeed("echo private-cover > /srv/media/romm/resources/test.txt")
    code = request("/assets/romm/resources/test.txt", "-o /dev/null -w '%{http_code}'")
    assert code in ("401", "403"), code
    for path in ("/library/test.rom", "/cache/test.zip", "/decode", "/openapi.json"):
        assert request(path, "-o /dev/null -w '%{http_code}'") == "404", path

with subtest("the watcher reacts to library changes"):
    machine.succeed("install -d -o romm -g media /srv/media/romm/library/roms/gba")
    machine.succeed("touch /srv/media/romm/library/roms/gba/test.gba")
    machine.wait_until_succeeds("journalctl -u romm-watcher | grep -iq rescan", timeout=60)

with subtest("MariaDB state survives startup migrations on restart"):
    request("/api/heartbeat", "--fail --cookie-jar /tmp/romm.cookies")
    cookies = machine.succeed("cat /tmp/romm.cookies")
    csrf_token = next(
        fields[-1]
        for line in cookies.splitlines()
        if len(fields := line.split()) == 7 and fields[-2] == "romm_csrftoken"
    )
    user = {
        "username": "admin",
        "email": "admin@example.invalid",
        "password": "Test-admin-password-123!",
        "role": "admin",
    }
    arguments = (
        "--fail-with-body --cookie /tmp/romm.cookies "
        f"--header {shlex.quote('X-CSRFToken: ' + csrf_token)} "
        f"--json {shlex.quote(json.dumps(user))}"
    )
    created = json.loads(request("/api/users", arguments))
    assert created["username"] == "admin"
    assert not heartbeat()["SYSTEM"]["SHOW_SETUP_WIZARD"]

    machine.succeed("systemctl restart romm.service")
    assert not heartbeat()["SYSTEM"]["SHOW_SETUP_WIZARD"]
