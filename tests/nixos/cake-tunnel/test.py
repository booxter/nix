# ruff: noqa: F821
# The NixOS test driver supplies the machines and subtest context manager.

import json
import shlex


def command(arguments):
    return shlex.join(str(value) for value in arguments)


def run(machine, *arguments):
    return machine.succeed(command(arguments))


def tunnel(machine, address, remote_address, remote_key):
    run(machine, "ip", "link", "add", "wg0", "type", "wireguard")
    run(
        machine,
        "wg",
        "set",
        "wg0",
        "private-key",
        "/run/wg.key",
        "listen-port",
        "1637",
        "peer",
        remote_key,
        "allowed-ips",
        "10.77.0.0/24",
        "endpoint",
        f"{remote_address}:1637",
    )
    run(machine, "ip", "address", "add", f"{address}/24", "dev", "wg0")
    run(machine, "ip", "link", "set", "wg0", "mtu", "1420", "up")


def configure(mode):
    client.succeed("systemctl stop qos-tunnel.service")
    client.execute("tc qdisc del dev wg0 root")
    client.execute("tc qdisc del dev wg0 ingress")
    client.execute("ip link del ifb-inner")
    if mode == "outer":
        client.succeed("systemctl start qos-tunnel.service")
        return

    # Outer IPv4/UDP/WireGuard plus Ethernet is 74 bytes; padding adds up to 15.
    # Charge the worst case so inner shaping cannot silently exceed the cap.
    options = ["besteffort", "triple-isolate", "overhead", "89"]
    run(
        client,
        "tc",
        "qdisc",
        "add",
        "dev",
        "wg0",
        "root",
        "cake",
        "bandwidth",
        "6mbit",
        *options,
        "ack-filter" if mode == "inner-ack" else "no-ack-filter",
    )
    run(client, "ip", "link", "add", "ifb-inner", "type", "ifb")
    run(client, "ip", "link", "set", "ifb-inner", "up")
    run(client, "tc", "qdisc", "add", "dev", "wg0", "ingress")
    run(
        client,
        "tc",
        "filter",
        "add",
        "dev",
        "wg0",
        "parent",
        "ffff:",
        "protocol",
        "all",
        "matchall",
        "action",
        "mirred",
        "egress",
        "redirect",
        "dev",
        "ifb-inner",
    )
    run(
        client,
        "tc",
        "qdisc",
        "add",
        "dev",
        "ifb-inner",
        "root",
        "cake",
        "bandwidth",
        "80mbit",
        *options,
        "ingress",
    )


def start_job(name, arguments):
    run(
        client,
        "systemd-run",
        "--no-block",
        "--setenv=PATH=/run/current-system/sw/bin:/run/wrappers/bin",
        f"--unit={name}",
        "--property=Type=oneshot",
        "--property=RemainAfterExit=yes",
        "--property=StandardError=journal+console",
        f"--property=StandardOutput=file:/tmp/{name}.json",
        *arguments,
    )


def result(name):
    client.wait_until_succeeds(
        f'test "$(systemctl show {name}.service --property ActiveState --value)" != activating',
        timeout=90,
    )
    client.succeed(f"systemctl is-active {name}.service")
    return json.loads(run(client, "cat", f"/tmp/{name}.json"))


def measure(mode, iteration):
    configure(mode)
    client.succeed("ping -n -c 3 -W 2 10.77.0.2")
    prefix = f"{mode}-{iteration}"
    common = ["iperf3", "--client", "10.77.0.2", "--time", "40", "--omit", "2", "--json"]
    start_job(f"{prefix}-download", [*common, "--port", "5201", "--reverse", "--parallel", "8"])
    start_job(f"{prefix}-upload", [*common, "--port", "5202", "--parallel", "2"])
    client.sleep(3)
    start_job(f"{prefix}-probes", ["python3", "/etc/cake-tunnel/probes.py"])
    probes = result(f"{prefix}-probes")
    # Queue sampling must finish under load, including on slower builders.
    for direction in ("download", "upload"):
        state = run(
            client,
            "systemctl",
            "show",
            f"{prefix}-{direction}.service",
            "--property=ActiveState",
            "--value",
        )
        assert state.strip() == "activating", (direction, state)
    transfers = {direction: result(f"{prefix}-{direction}") for direction in ("download", "upload")}
    summary = {"mode": mode, "iteration": iteration, "ping": probes["ping"], "dns": probes["dns"]}
    for direction, transfer in transfers.items():
        assert "error" not in transfer, transfer
        end = transfer["end"]
        summary[direction] = {
            "mbit": end["sum_received"]["bits_per_second"] / 1e6,
            "retransmits": end["sum_sent"]["retransmits"],
        }
        assert summary[direction]["mbit"] > 0.1, summary
    states = [
        q
        for sample in probes["queues"]
        for queues in sample["queues"].values()
        for q in queues
        if q["kind"] == "cake"
    ]
    summary["queue_peak_delay_ms"] = max(
        t["peak_delay_us"] / 1000 for q in states for t in q["tins"]
    )
    summary["ack_drops"] = max(sum(t["ack_drops"] for t in q["tins"]) for q in states)
    summary["blue_probability_max"] = max(
        (flow["blue_prob"] / 2**32 for queue in states for flow in queue["flows"]), default=0
    )
    first, last = probes["queues"][0], probes["queues"][-1]
    elapsed = last["time"] - first["time"]
    summary["outer_mbit"] = {
        direction: (
            last["link"]["stats64"][direction]["bytes"]
            - first["link"]["stats64"][direction]["bytes"]
        )
        * 8
        / elapsed
        / 1e6
        for direction in ("rx", "tx")
    }
    assert probes["ping"]["sent"] == 100, probes
    assert probes["dns"]["sent"] == 80, probes
    assert probes["ping"]["lost"] < probes["ping"]["sent"], probes["ping"]
    assert probes["dns"]["lost"] < probes["dns"]["sent"], probes["dns"]
    if mode == "inner-ack":
        assert summary["ack_drops"] > 0, summary
    else:
        assert summary["ack_drops"] == 0, summary
    (driver.out_dir / f"{prefix}.json").write_text(
        json.dumps({"summary": summary, "probes": probes, "transfers": transfers}, indent=2)
    )
    print(f"CAKE tunnel comparison: {json.dumps(summary, sort_keys=True)}")
    return summary


start_all()
for machine in (client, provider, wan):
    machine.wait_for_unit("multi-user.target")
for device in ("eth1", "eth2"):
    run(
        wan,
        "tc",
        "qdisc",
        "replace",
        "dev",
        device,
        "root",
        "netem",
        "delay",
        "20ms",
        "rate",
        "200mbit",
        "limit",
        "10000",
    )

keys = {}
for name, machine in (("client", client), ("provider", provider)):
    machine.succeed("umask 077; wg genkey > /run/wg.key")
    keys[name] = machine.succeed("wg pubkey < /run/wg.key").strip()
tunnel(client, "10.77.0.1", "10.10.2.1", keys["provider"])
tunnel(provider, "10.77.0.2", "10.10.1.1", keys["client"])
client.succeed("ping -n -c 3 -W 2 10.77.0.2")
provider.wait_for_unit("dnsmasq.service")
for port in (5201, 5202):
    run(provider, "iperf3", "--server", "--daemon", "--port", port)
    provider.wait_for_open_port(port)

summaries = []
for iteration, modes in enumerate(
    (("outer", "inner", "inner-ack"), ("inner-ack", "inner", "outer"))
):
    for mode in modes:
        with subtest(f"{mode}, repetition {iteration + 1}"):
            summaries.append(measure(mode, iteration + 1))
(driver.out_dir / "comparison.json").write_text(json.dumps(summaries, indent=2))
