from __future__ import annotations

from pathlib import Path

from arr_post_processor.lidarr_agent_state import (
    FailureKind,
    JobStatus,
    RepairJob,
    RepairState,
)
from arr_post_processor.lidarr_metrics import METRICS_PREFIX, render_lidarr_metrics
from prometheus_client.parser import text_string_to_metric_families


def metric_value(metrics: str, name: str, labels: dict[str, str] | None = None) -> float:
    expected_labels = labels or {}
    for family in text_string_to_metric_families(metrics):
        for sample in family.samples:
            if sample.name == name and sample.labels == expected_labels:
                return sample.value
    raise AssertionError(f"missing metric {name} with labels {expected_labels}")


def test_lidarr_metrics_expose_handoff_states_and_outcomes() -> None:
    state = RepairState(
        jobs={
            "active": RepairJob(
                download_id="active",
                source_path=Path("/downloads/active"),
                status=JobStatus.AGENT_RUNNING,
                discovered_at=900,
                updated_at=990,
            ),
            "attention": RepairJob(
                download_id="attention",
                source_path=Path("/downloads/attention"),
                status=JobStatus.NEEDS_ATTENTION,
                discovered_at=800,
                updated_at=980,
                failure_kind=FailureKind.AGENT_UNRESOLVED,
            ),
        },
        last_success=950,
        last_duration=120,
    )
    state.totals.success = 3
    state.totals.agent_unresolved = 1
    state.totals.tracks = 20

    metrics = render_lidarr_metrics(state, ok=True, now=1000)

    assert metric_value(metrics, f"{METRICS_PREFIX}_ok") == 1
    assert metric_value(metrics, f"{METRICS_PREFIX}_active") == 1
    assert (
        metric_value(
            metrics,
            f"{METRICS_PREFIX}_jobs",
            {"state": JobStatus.AGENT_RUNNING.value},
        )
        == 1
    )
    assert (
        metric_value(
            metrics,
            f"{METRICS_PREFIX}_jobs_total",
            {"result": FailureKind.AGENT_UNRESOLVED.value},
        )
        == 1
    )
    assert metric_value(metrics, f"{METRICS_PREFIX}_tracks_total") == 20
