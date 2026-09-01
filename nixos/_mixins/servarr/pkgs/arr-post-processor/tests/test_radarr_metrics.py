from __future__ import annotations

from prometheus_client.parser import text_string_to_metric_families

from arr_post_processor.radarr_metrics import METRICS_PREFIX, render_radarr_metrics
from arr_post_processor.radarr_state import (
    FailureKind,
    JobStatus,
    RepairJob,
    RepairState,
)


def metric_value(metrics: str, name: str, labels: dict[str, str] | None = None) -> float:
    expected_labels = labels or {}
    for family in text_string_to_metric_families(metrics):
        for sample in family.samples:
            if sample.name == name and sample.labels == expected_labels:
                return sample.value
    raise AssertionError(f"missing metric {name} with labels {expected_labels}")


def test_radarr_metrics_expose_handoff_states_and_outcomes() -> None:
    state = RepairState(
        jobs={
            "active": RepairJob(
                download_id="active",
                status=JobStatus.AGENT_RUNNING,
                discovered_at=900,
                updated_at=990,
            ),
            "attention": RepairJob(
                download_id="attention",
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

    metrics = render_radarr_metrics(state, ok=True, now=1000)

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
            f"{METRICS_PREFIX}_jobs",
            {"state": JobStatus.NEEDS_ATTENTION.value},
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
    assert metric_value(metrics, f"{METRICS_PREFIX}_last_success_timestamp_seconds") == 950
