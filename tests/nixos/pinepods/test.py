# ruff: noqa: F821
# NixOS test-driver globals and Nix-generated constants are prepended at evaluation.

start_all()
machine.wait_for_unit("postgresql.service")
machine.wait_for_unit("pinepods-valkey.service")
machine.wait_for_unit("podman-pinepods.service")
machine.wait_until_succeeds(
    f"curl -sf http://127.0.0.1:8040/api/health | {JQ} -e '.database and .redis'"
)
machine.wait_for_unit("pinepods-bootstrap-admin.service")
machine.succeed(
    "curl -sf http://127.0.0.1:8040/api/data/self_service_status"
    f" | {JQ} -e '.first_admin_created == true'"
)
machine.succeed("runuser -u pinepods -- test -w /srv/podcasts/podcasts/pinepods")
