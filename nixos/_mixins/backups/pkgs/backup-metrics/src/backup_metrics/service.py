from __future__ import annotations

from .models import JobsConfig, Outcome
from .state import updated_state
from .storage import MetricsStore
from .systemd import DurationSource


def publish(configuration: JobsConfig, store: MetricsStore) -> None:
    states = {}
    for job in configuration.jobs:
        state = store.read(job.backup_job)
        if state is not None:
            states[job.backup_job] = state

    store.publish(configuration, states)


def configure(configuration: JobsConfig, store: MetricsStore) -> None:
    with store.transaction():
        # Recorders read this live manifest, never the store path captured by an
        # older service generation. A retired job cannot reintroduce its metrics.
        store.configure(configuration)
        publish(configuration, store)


def record(
    job_name: str,
    store: MetricsStore,
    outcome: Outcome,
    duration_source: DurationSource,
    *,
    now: float,
) -> None:
    with store.transaction():
        configuration = store.configuration()
        job = next((job for job in configuration.jobs if job.backup_job == job_name), None)
        if job is None:
            return

        state = updated_state(
            store.read(job_name),
            outcome,
            now=now,
            duration=duration_source.duration_seconds(job.unit),
        )
        store.write(job_name, state)
        publish(configuration, store)
