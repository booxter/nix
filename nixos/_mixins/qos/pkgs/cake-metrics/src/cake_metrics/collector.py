import logging
import subprocess
import time
from pathlib import Path

from atomic_file_writes import write_bytes_atomic
from prometheus_client import CollectorRegistry, generate_latest
from prometheus_client.core import CounterMetricFamily, GaugeMetricFamily

from .models import Flow, Qdisc, Target
from .source import Source

PREFIX = "host_observability_cake_"
LABELS = ["profile", "limit", "direction", "device"]
logger = logging.getLogger(__name__)


class Metrics:
    def __init__(self) -> None:
        self.families: dict[str, GaugeMetricFamily | CounterMetricFamily] = {}

    def add(
        self,
        name: str,
        description: str,
        target: Target,
        value: float,
        *,
        counter: bool = False,
        tin: int | None = None,
    ) -> None:
        labels = LABELS + ([] if tin is None else ["tin"])
        if name not in self.families:
            kind = CounterMetricFamily if counter else GaugeMetricFamily
            self.families[name] = kind(PREFIX + name, description, labels=labels)
        values = [target.profile, target.limit, target.direction, target.device]
        if tin is not None:
            values.append(str(tin))
        self.families[name].add_metric(values, value)

    def queue(self, target: Target, queue: Qdisc, flows: list[Flow]) -> None:
        for name, description, queue_value, counter in [
            (
                "rate_bits_per_second",
                "Configured CAKE shaping rate.",
                queue.options.bandwidth * 8,
                False,
            ),
            ("sent_bytes", "Bytes delivered by this queue.", queue.bytes, True),
            ("sent_packets", "Packets delivered by this queue.", queue.packets, True),
            (
                "dropped_packets",
                "Packets dropped by this queue, across all reasons.",
                queue.drops,
                True,
            ),
            ("backlog_bytes", "Current queued bytes.", queue.backlog, False),
            ("backlog_packets", "Current queued packets.", queue.qlen, False),
        ]:
            self.add(name, description, target, queue_value, counter=counter)
        for index, tin in enumerate(queue.tins):
            states = [flow.stats for flow in flows if flow.tin == index]
            for name, description, value in [
                (
                    "blue_probability_max",
                    "Maximum BLUE drop probability; not measured loss.",
                    max((s.blue_prob for s in states), default=0) / 2**32,
                ),
                (
                    "blue_flows",
                    "Flow buckets with a nonzero BLUE penalty.",
                    sum(s.blue_prob > 0 for s in states),
                ),
                (
                    "blue_empty_flows",
                    "Penalized flow buckets empty at the sample instant.",
                    sum(s.blue_prob > 0 and s.backlog == 0 for s in states),
                ),
                (
                    "codel_dropping_flows",
                    "Flow buckets in CoDel dropping state.",
                    sum(s.dropping for s in states),
                ),
                (
                    "codel_count_max",
                    "Maximum CoDel control-law count.",
                    max((s.count for s in states), default=0),
                ),
                (
                    "delay_average_seconds",
                    "CAKE average queue-delay estimate.",
                    tin.avg_delay_us / 1e6,
                ),
                (
                    "delay_peak_seconds",
                    "CAKE peak queue-delay estimate, not an interval maximum.",
                    tin.peak_delay_us / 1e6,
                ),
                ("delay_base_seconds", "CAKE base queue-delay estimate.", tin.base_delay_us / 1e6),
                ("sparse_flows", "CAKE sparse flow count.", tin.sparse_flows),
                ("bulk_flows", "CAKE bulk flow count.", tin.bulk_flows),
                ("unresponsive_flows", "CAKE unresponsive flow count.", tin.unresponsive_flows),
            ]:
                self.add(name, description, target, value, tin=index)
            self.add(
                "ecn_marks",
                "ECN marks applied by CAKE.",
                target,
                tin.ecn_mark,
                counter=True,
                tin=index,
            )

    def render(self) -> bytes:
        registry = CollectorRegistry()
        for family in self.families.values():
            # A fresh registry makes failed queues disappear instead of retaining stale values.
            registry.register(FamilyCollector(family))
        return generate_latest(registry)


class FamilyCollector:
    def __init__(self, family: GaugeMetricFamily | CounterMetricFamily) -> None:
        self.family = family

    def collect(self) -> list[GaugeMetricFamily | CounterMetricFamily]:
        return [self.family]


def collect(source: Source, targets: list[Target], output: Path) -> bool:
    metrics = Metrics()
    healthy = True
    for target in targets:
        started = time.monotonic()
        success = True
        try:
            queue, flows = source.read(target)
            metrics.queue(target, queue, flows)
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            success = False
            healthy = False
            logger.error(
                "CAKE collection failed for %s/%s: %s", target.profile, target.limit, error
            )
        metrics.add(
            "collection_success", "Whether the latest collection succeeded.", target, float(success)
        )
        metrics.add(
            "collection_timestamp_seconds",
            "Time of the latest collection attempt.",
            target,
            time.time(),
        )
        metrics.add(
            "collection_duration_seconds",
            "Time spent collecting this queue.",
            target,
            time.monotonic() - started,
        )
    write_bytes_atomic(output, metrics.render(), mode=0o644)
    return healthy
