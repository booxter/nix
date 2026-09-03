from __future__ import annotations

from collections import Counter
from collections.abc import Iterable

from prometheus_client import CollectorRegistry, generate_latest
from prometheus_client.core import GaugeMetricFamily, Metric

from .lidarr_agent_state import ACTIVE_AGENT_STATES, FailureKind, JobStatus, RepairState

METRICS_PREFIX = "host_observability_lidarr_post_processor"
ACTIVE_STATES = ACTIVE_AGENT_STATES | {
    JobStatus.SETTLING,
    JobStatus.READY,
    JobStatus.STAGED,
    JobStatus.IMPORTING,
    JobStatus.AWAITING_QUEUE_REMOVAL,
}


def _gauge(name: str, documentation: str, value: float) -> GaugeMetricFamily:
    metric = GaugeMetricFamily(f"{METRICS_PREFIX}_{name}", documentation)
    metric.add_metric([], value)
    return metric


class LidarrCollector:
    def __init__(self, state: RepairState, *, ok: bool, now: float) -> None:
        self.state = state
        self.ok = ok
        self.now = now

    def collect(self) -> Iterable[Metric]:
        states = Counter(job.status for job in self.state.jobs.values())
        yield _gauge("ok", "Whether the latest service iteration completed successfully.", self.ok)
        yield _gauge(
            "last_run_timestamp_seconds", "Unix timestamp of the latest iteration.", self.now
        )
        yield _gauge(
            "active",
            "Whether a Lidarr repair or import job is active.",
            any(states[state] for state in ACTIVE_STATES),
        )
        jobs = GaugeMetricFamily(
            f"{METRICS_PREFIX}_jobs",
            "Number of known Lidarr repair jobs by state.",
            labels=["state"],
        )
        for state in JobStatus:
            jobs.add_metric([state.value], states[state])
        yield jobs
        totals = Metric(
            f"{METRICS_PREFIX}_jobs_total",
            "Lidarr repair jobs handled by result.",
            "counter",
        )
        for result in ("success", "manual", *(kind.value for kind in FailureKind)):
            totals.add_sample(
                f"{METRICS_PREFIX}_jobs_total",
                {"result": result},
                getattr(self.state.totals, result),
            )
        yield totals
        tracks = Metric(
            f"{METRICS_PREFIX}_tracks_total", "Tracks imported by successful repairs.", "counter"
        )
        tracks.add_sample(f"{METRICS_PREFIX}_tracks_total", {}, self.state.totals.tracks)
        yield tracks
        yield _gauge(
            "last_job_duration_seconds",
            "Duration of the latest successful repair and import.",
            self.state.last_duration,
        )
        if self.state.last_success is not None:
            yield _gauge(
                "last_success_timestamp_seconds",
                "Unix timestamp of the latest successful repair and import.",
                self.state.last_success,
            )


def render_lidarr_metrics(state: RepairState, *, ok: bool, now: float) -> str:
    registry = CollectorRegistry()
    registry.register(LidarrCollector(state, ok=ok, now=now))
    return generate_latest(registry).decode()
