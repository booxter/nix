from __future__ import annotations

from collections import Counter
from collections.abc import Iterator
from dataclasses import dataclass

from prometheus_client import CollectorRegistry, generate_latest
from prometheus_client.core import CounterMetricFamily, GaugeMetricFamily, Metric

from .models import ServiceState


KNOWN_STATES = {"complete", "converting", "failed", "needs_attention", "settling"}


@dataclass(frozen=True, eq=False)
class EbookMetricsCollector:
    state: ServiceState
    ok: bool
    now: float

    def collect(self) -> Iterator[Metric]:
        latest_ok = GaugeMetricFamily(
            "host_observability_ebook_converter_ok",
            "Whether the latest service iteration completed successfully.",
        )
        latest_ok.add_metric([], int(self.ok))
        yield latest_ok

        last_run = GaugeMetricFamily(
            "host_observability_ebook_converter_last_run_timestamp_seconds",
            "Unix timestamp of the latest iteration.",
        )
        last_run.add_metric([], self.now)
        yield last_run

        states = Counter(job.status for job in self.state.files.values())
        files = GaugeMetricFamily(
            "host_observability_ebook_converter_files",
            "Number of known files by state.",
            labels=["state"],
        )
        for state_name in sorted(set(states) | KNOWN_STATES):
            files.add_metric([state_name], states[state_name])
        yield files

        attempts = CounterMetricFamily(
            "host_observability_ebook_converter_files",
            "Conversion attempts by result.",
            labels=["result"],
        )
        attempts.add_metric(["success"], self.state.totals.success)
        attempts.add_metric(["failed"], self.state.totals.failed)
        yield attempts

        if self.state.last_success is not None:
            last_success = GaugeMetricFamily(
                "host_observability_ebook_converter_last_success_timestamp_seconds",
                "Unix timestamp of the latest successful conversion.",
            )
            last_success.add_metric([], self.state.last_success)
            yield last_success


def prometheus_metrics(state: ServiceState, ok: bool, now: float) -> str:
    registry = CollectorRegistry()
    registry.register(EbookMetricsCollector(state=state, ok=ok, now=now))
    return generate_latest(registry).decode("utf-8")
