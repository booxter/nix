from __future__ import annotations

from collections import Counter
from collections.abc import Iterable

from prometheus_client import CollectorRegistry, generate_latest
from prometheus_client.core import GaugeMetricFamily, Metric

from .state import ACTIVE_JOB_STATES, KNOWN_JOB_STATES, State


DEFAULT_PREFIX = "host_observability_lidarr_post_processor"


def gauge(prefix: str, name: str, documentation: str, value: float) -> GaugeMetricFamily:
    metric = GaugeMetricFamily(f"{prefix}_{name}", documentation)
    metric.add_metric([], value)
    return metric


class PostProcessorCollector:
    def __init__(self, state: State, *, prefix: str, ok: bool, now: float):
        self.state = state
        self.prefix = prefix
        self.ok = ok
        self.now = now

    def collect(self) -> Iterable[Metric]:
        states = Counter(job.status for job in self.state.jobs.values())
        yield gauge(
            self.prefix,
            "ok",
            "Whether the latest service iteration completed successfully.",
            self.ok,
        )
        yield gauge(
            self.prefix,
            "last_run_timestamp_seconds",
            "Unix timestamp of the latest iteration.",
            self.now,
        )
        yield gauge(
            self.prefix,
            "active",
            "Whether a transformation or import job is active.",
            any(states[state] for state in ACTIVE_JOB_STATES),
        )

        jobs = GaugeMetricFamily(
            f"{self.prefix}_jobs",
            "Number of known jobs by state.",
            labels=["state"],
        )
        for state in sorted(set(states) | KNOWN_JOB_STATES):
            jobs.add_metric([state], states[state])
        yield jobs

        totals = Metric(
            f"{self.prefix}_jobs_total",
            "Jobs handled by result.",
            "counter",
        )
        for result in (
            "success",
            "failed",
            "ignored",
            "manual",
            "source_invalid",
            "source_unavailable",
        ):
            totals.add_sample(
                f"{self.prefix}_jobs_total",
                {"result": result},
                getattr(self.state.totals, result),
            )
        yield totals

        tracks = Metric(
            f"{self.prefix}_tracks_total",
            "Tracks imported by successful jobs.",
            "counter",
        )
        tracks.add_sample(f"{self.prefix}_tracks_total", {}, self.state.totals.tracks)
        yield tracks
        yield gauge(
            self.prefix,
            "last_job_duration_seconds",
            "Duration of the latest successful job.",
            self.state.last_duration,
        )
        if self.state.last_success is not None:
            yield gauge(
                self.prefix,
                "last_success_timestamp_seconds",
                "Unix timestamp of the latest successful import.",
                self.state.last_success,
            )


def render_metrics(state: State, *, ok: bool, now: float, prefix: str = DEFAULT_PREFIX) -> str:
    registry = CollectorRegistry()
    registry.register(PostProcessorCollector(state, prefix=prefix, ok=ok, now=now))
    return generate_latest(registry).decode()
