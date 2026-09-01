from __future__ import annotations

from pathlib import Path

from nix_builder_metrics.exporter import write_metrics
from nix_builder_metrics.model import Sample
from prometheus_client.parser import text_string_to_metric_families


def test_writes_prometheus_metrics(tmp_path: Path) -> None:
    output = tmp_path / "metrics.prom"
    sample = Sample(2, 3, 4.5, 6, 7, 8, 9, 10.5)

    write_metrics(output, 4, sample, success=True)

    metrics = {
        metric.name: metric.samples[0].value
        for metric in text_string_to_metric_families(output.read_text())
    }
    assert metrics["host_observability_nix_builder_configured_slots"] == 4
    assert metrics["host_observability_nix_builder_active_slots"] == 2
    assert metrics["host_observability_nix_builder_cpu_seconds"] == 4.5
    assert metrics["host_observability_nix_builder_collect_success"] == 1
