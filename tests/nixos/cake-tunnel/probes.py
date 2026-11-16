"""Concurrent probes and queue sampling inside the isolated test VM."""

import argparse
import asyncio
import json
import re
import statistics
import time
from pathlib import Path

import dns.asyncquery
import dns.exception
import dns.message
import dns.rcode

TARGET = "10.77.0.2"
DURATION = 20


async def command(*arguments):
    process = await asyncio.create_subprocess_exec(
        *arguments, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE
    )
    stdout, stderr = await process.communicate()
    if process.returncode:
        raise RuntimeError(f"{arguments}: {stderr.decode()}")
    return stdout.decode()


async def dns_probe():
    started = asyncio.get_running_loop().time()
    timestamp = time.time()
    try:
        answer = await dns.asyncquery.udp(
            dns.message.make_query("probe.test", "A"), TARGET, timeout=1
        )
        if answer.rcode() != dns.rcode.NOERROR or not answer.answer:
            return {"time": timestamp, "latency_ms": None}
        return {
            "time": timestamp,
            "latency_ms": (asyncio.get_running_loop().time() - started) * 1000,
        }
    except (TimeoutError, OSError, dns.exception.DNSException):
        return {"time": timestamp, "latency_ms": None}


async def dns_probes():
    pending = []
    for _ in range(DURATION * 4):
        pending.append(asyncio.create_task(dns_probe()))
        await asyncio.sleep(0.25)
    results = await asyncio.gather(*pending)
    latencies = sorted(value["latency_ms"] for value in results if value["latency_ms"] is not None)
    return {
        "sent": len(results),
        "lost": len(results) - len(latencies),
        "p95_ms": latencies[int((len(latencies) - 1) * 0.95)] if latencies else None,
        "samples": results,
    }


async def ping_probes():
    process = await asyncio.create_subprocess_exec(
        "ping",
        "-D",
        "-n",
        "-i",
        "0.2",
        "-c",
        str(DURATION * 5),
        "-W",
        "1",
        TARGET,
        stdout=asyncio.subprocess.PIPE,
    )
    stdout, _ = await process.communicate()
    text = stdout.decode()
    summary = re.search(r"(\d+) packets transmitted, (\d+) received", text)
    if summary is None:
        raise RuntimeError(text)
    latencies = sorted(float(value) for value in re.findall(r"time=([\d.]+) ms", text))
    return {
        "sent": int(summary[1]),
        "lost": int(summary[1]) - int(summary[2]),
        "p95_ms": latencies[int((len(latencies) - 1) * 0.95)] if latencies else None,
        "mean_ms": statistics.mean(latencies) if latencies else None,
        "samples": [
            {"time": float(timestamp), "sequence": int(sequence), "latency_ms": float(latency)}
            for timestamp, sequence, latency in re.findall(
                r"\[([\d.]+)\].*icmp_seq=(\d+).*time=([\d.]+) ms", text
            )
        ],
    }


def system_state():
    return {
        "time": time.time(),
        "clocksource": Path("/sys/devices/system/clocksource/clocksource0/current_clocksource")
        .read_text()
        .strip(),
        **{
            name: Path(path).read_text()
            for name, path in {
                "cpu": "/proc/stat",
                "softirqs": "/proc/softirqs",
                "softnet": "/proc/net/softnet_stat",
                "cpu_pressure": "/proc/pressure/cpu",
            }.items()
        },
    }


async def system_samples(duration):
    samples = []
    started = asyncio.get_running_loop().time()
    for index in range(duration):
        samples.append(await asyncio.to_thread(system_state))
        await asyncio.sleep(max(0, started + index + 1 - asyncio.get_running_loop().time()))
    return samples


async def queues():
    samples = []
    started = asyncio.get_running_loop().time()
    for index in range(DURATION):
        sample = {
            "time": asyncio.get_running_loop().time(),
            "wall_time": time.time(),
            "link": json.loads(await command("ip", "-j", "-s", "link", "show", "dev", "eth1"))[0],
            "queues": {},
            "classes": {},
        }
        for device in ("eth1", "wg0", "ifb-q0-0", "ifb-inner"):
            # Some interfaces belong only to one of the compared placements.
            if not await asyncio.to_thread(Path(f"/sys/class/net/{device}").exists):
                continue
            sample["queues"][device] = json.loads(
                await command("tc", "-j", "-s", "qdisc", "show", "dev", device)
            )
            flows = json.loads(await command("tc", "-j", "-s", "class", "show", "dev", device))
            sample["classes"][device] = flows
            for queue in sample["queues"][device]:
                if queue["kind"] == "cake":
                    queue["flows"] = [
                        flow["stats"] for flow in flows if flow.get("parent") == queue["handle"]
                    ]
        samples.append(sample)
        await asyncio.sleep(max(0, started + index + 1 - asyncio.get_running_loop().time()))
    return samples


async def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--system-only", type=int, metavar="SECONDS")
    arguments = parser.parse_args()
    if arguments.system_only:
        print(json.dumps(await system_samples(arguments.system_only)))
        return

    ping, dns, state = await asyncio.gather(ping_probes(), dns_probes(), queues())
    print(
        json.dumps(
            {"ping": ping, "dns": dns, "queues": state, "finished_monotonic": time.monotonic()}
        )
    )


asyncio.run(main())
