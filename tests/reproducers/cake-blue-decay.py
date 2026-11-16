# ruff: noqa: F821
# The NixOS test driver supplies the machines and subtest context manager.

import json
import shlex


def command(arguments):
    return shlex.join(str(argument) for argument in arguments)


def cake_state():
    queues = json.loads(receiver.succeed("tc -j -s qdisc show dev ifb0"))
    flows = json.loads(receiver.succeed("tc -j -s class show dev ifb0"))
    return {
        "queue": queues[0],
        "flows": flows,
    }


def report(label):
    state = cake_state()
    print(f"{label}: {json.dumps(state, sort_keys=True)}")
    return state


def create_queue():
    receiver.succeed(
        "tc qdisc add dev ifb0 root cake bandwidth 10mbit "
        "besteffort triple-isolate ingress memlimit 128kb"
    )


def transfer(rate, seconds=5):
    # Reuse the UDP five-tuple across runs, like an established VPN tunnel.
    # TCP control traffic bypasses CAKE so it cannot service a second flow.
    # Low-rate runs use 20-packet bursts: isolated packets would exercise
    # CAKE's last-packet exemption even when BLUE's probability is stuck.
    result = json.loads(
        sender.succeed(
            command(
                [
                    "iperf3",
                    "--client",
                    "192.168.1.1",
                    "--udp",
                    "--cport",
                    "40000",
                    "--length",
                    "1200",
                    "--bitrate",
                    rate,
                    "--pacing-timer",
                    "10000",
                    "--time",
                    seconds,
                    "--json",
                ]
            )
        )
    )
    assert "error" not in result, result
    summary = result["end"]["sum_received"]
    print(f"UDP transfer at {rate}: {json.dumps(summary, sort_keys=True)}")
    return summary["lost_percent"]


start_all()
receiver.wait_for_unit("multi-user.target")
sender.wait_for_unit("multi-user.target")
print(receiver.succeed("uname -r"))
receiver.succeed("ip link add ifb0 type ifb")
receiver.succeed("ip link set ifb0 up")
create_queue()
receiver.succeed("tc qdisc add dev eth1 ingress")
receiver.succeed(
    "tc filter add dev eth1 parent ffff: protocol ip flower "
    "ip_proto udp dst_port 5201 action mirred egress redirect dev ifb0"
)
receiver.succeed("iperf3 --server --daemon")
receiver.wait_for_open_port(5201)

with subtest("below-limit traffic starts with negligible loss"):
    baseline_loss = transfer("2M/20")
    report("baseline")
    assert baseline_loss < 1, baseline_loss

with subtest("overload followed by idle leaves persistent below-limit loss"):
    transfer("20M")
    report("after overload")
    # Ingress also charges dropped bytes to its virtual clock. This pause
    # exceeds that debt as well as BLUE's full-scale decay time: 4096
    # decrements at the default 5 ms target take about 20.5 seconds.
    receiver.sleep(30)
    idle = report("after idle")
    assert idle["queue"]["backlog"] == 0, idle

    affected_loss = transfer("2M/20")
    report("after below-limit traffic")
    assert affected_loss > 5, f"Persistent-loss bug did not reproduce: {affected_loss:.2f}% loss"

with subtest("recreating only the queue restores delivery"):
    receiver.succeed("tc qdisc del dev ifb0 root")
    create_queue()
    reset_loss = transfer("2M/20")
    report("after queue recreation")
    assert reset_loss < 1, reset_loss

print(
    f"Reproduced persistent CAKE loss: baseline={baseline_loss:.2f}%, "
    f"after overload and idle={affected_loss:.2f}%, reset={reset_loss:.2f}%"
)

with subtest("load the candidate module without changing the running kernel"):
    receiver.succeed("tc qdisc del dev ifb0 root")
    receiver.succeed("modprobe -r sch_cake")
    receiver.succeed(command(["insmod", candidate_module]))
    create_queue()

with subtest("candidate still activates BLUE during overload"):
    candidate_baseline = transfer("2M/20")
    assert candidate_baseline < 1, candidate_baseline
    overload_loss = transfer("20M")
    overloaded = report("candidate after overload")
    assert overload_loss > 5, overload_loss
    assert any(flow["stats"]["blue_prob"] > 0 for flow in overloaded["flows"]), overloaded

with subtest("short idle reduces the penalty without resetting it"):
    receiver.sleep(1)
    transfer("10K", seconds=1)
    partially_recovered = report("candidate after short idle")
    before = max(flow["stats"]["blue_prob"] for flow in overloaded["flows"])
    after = max(flow["stats"]["blue_prob"] for flow in partially_recovered["flows"])
    assert 0 < after < before, (before, after)

with subtest("long idle clears the remaining penalty"):
    receiver.sleep(30)
    candidate_loss = transfer("2M/20")
    recovered = report("candidate after idle and below-limit traffic")
    assert candidate_loss < 1, candidate_loss
    assert all(flow["stats"]["blue_prob"] == 0 for flow in recovered["flows"]), recovered
    assert recovered["queue"]["tins"][0]["unresponsive_flows"] == 0, recovered

print(f"Candidate recovery: {candidate_loss:.2f}% loss versus stock {affected_loss:.2f}%")
