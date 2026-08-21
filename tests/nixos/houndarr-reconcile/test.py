# ruff: noqa: F821
# NixOS test-driver globals and Nix-generated constants are prepended at evaluation.


def reconcile(expected_changes):
    reconciler.succeed("systemctl start houndarr-reconcile.service")
    reconciler.succeed(
        "journalctl -u houndarr-reconcile.service -n 20 -o cat "
        f"| grep -F 'Reconciled Houndarr instances: {expected_changes} changed.'"
    )


start_all()
arr.wait_for_unit("fake-lidarr.service")
arr.wait_for_open_port(9443)
reconciler.wait_for_unit("multi-user.target")

with subtest("declaration creates the instance"):
    reconcile(1)

with subtest("changed declaration updates the instance"):
    reconciler.succeed(f"{UPDATED_SYSTEM}/bin/switch-to-configuration test")
    reconcile(1)

with subtest("unchanged declaration is idempotent"):
    reconcile(0)
