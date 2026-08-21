# ruff: noqa: F821
# NixOS test-driver globals and Nix-generated constants are prepended at evaluation.


def heartbeat():
    machine.wait_until_succeeds(
        f"{CURL} --fail --show-error --cacert {CA_CERTIFICATE} "
        f"--resolve {SERVER_NAME}:443:127.0.0.1 "
        f"https://{SERVER_NAME}/api/heartbeat"
    )


start_all()

with subtest("the complete service graph starts"):
    machine.wait_for_unit("romm-setup.service")
    for unit in (
        "romm-web-assets.service",
        "mysql.service",
        "romm-valkey.service",
        "podman-romm-api.service",
        "podman-romm-scheduler.service",
        "podman-romm-worker.service",
        "podman-romm-watcher.service",
        "nginx.service",
    ):
        machine.wait_for_unit(unit)
    for unit in ("romm-db-init.service", "romm-backup.service"):
        machine.succeed(
            f"systemctl show --property=Result --value {unit} | grep -Fx success"
        )

with subtest("the HTTPS frontend reaches the RomM API"):
    machine.wait_for_open_port(443)
    heartbeat()

with subtest("setup is idempotent"):
    machine.succeed("systemctl restart romm-setup.service")
    heartbeat()
