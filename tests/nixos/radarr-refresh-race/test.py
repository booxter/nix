# ruff: noqa: F821
# The NixOS test driver supplies machine and subtest.

start_all()
machine.wait_for_unit("nginx.service")
machine.wait_for_open_port(7878)

with subtest("queued refreshes run in order and preserve alternative titles"):
    try:
        output = machine.succeed(
            "python3 /etc/radarr-refresh-probe.py /etc/radarr-metadata.json",
            timeout=180,
        )
        print(output)
    except Exception:
        print(machine.succeed("journalctl -u radarr -u nginx -n 200 --no-pager"))
        raise
