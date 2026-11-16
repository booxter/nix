"""Concurrent probes and queue sampling inside the isolated test VM."""

import asyncio
import json
import re
import statistics
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
    try:
        answer = await dns.asyncquery.udp(
            dns.message.make_query("probe.test", "A"), TARGET, timeout=1
        )
        if answer.rcode() != dns.rcode.NOERROR or not answer.answer:
            return None
        return asyncio.get_running_loop().time() - started
    except (TimeoutError, OSError, dns.exception.DNSException):
        return None


async def dns_probes():
    pending = []
    for _ in range(DURATION * 4):
        pending.append(asyncio.create_task(dns_probe()))
        await asyncio.sleep(0.25)
    results = await asyncio.gather(*pending)
    latencies = sorted(value for value in results if value is not None)
    return {
        "sent": len(results),
        "lost": len(results) - len(latencies),
        "p95_ms": latencies[int((len(latencies) - 1) * 0.95)] * 1000 if latencies else None,
    }


async def ping_probes():
    process = await asyncio.create_subprocess_exec(
        "ping",
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
    }


async def queues():
    samples = []
    for _ in range(DURATION):
        sample = {
            "time": asyncio.get_running_loop().time(),
            "link": json.loads(await command("ip", "-j", "-s", "link", "show", "dev", "eth1"))[0],
            "queues": {},
        }
        for device in ("eth1", "wg0", "ifb-q0-0", "ifb-inner"):
            # Some interfaces belong only to one of the compared placements.
            if not await asyncio.to_thread(Path(f"/sys/class/net/{device}").exists):
                continue
            sample["queues"][device] = json.loads(
                await command("tc", "-j", "-s", "qdisc", "show", "dev", device)
            )
            flows = json.loads(await command("tc", "-j", "-s", "class", "show", "dev", device))
            for queue in sample["queues"][device]:
                if queue["kind"] == "cake":
                    queue["flows"] = [
                        flow["stats"] for flow in flows if flow.get("parent") == queue["handle"]
                    ]
        samples.append(sample)
        await asyncio.sleep(1)
    return samples


async def main():
    ping, dns, state = await asyncio.gather(ping_probes(), dns_probes(), queues())
    print(json.dumps({"ping": ping, "dns": dns, "queues": state}))


asyncio.run(main())
