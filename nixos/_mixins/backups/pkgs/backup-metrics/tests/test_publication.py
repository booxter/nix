from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import pytest
from backup_metrics.models import BackupJob, JobsConfig, Outcome
from backup_metrics.service import configure, record
from backup_metrics.storage import FileMetricsStore
from prometheus_client.parser import text_string_to_metric_families
from prometheus_client.samples import Sample


class FixedDuration:
    def duration_seconds(self, unit_name: str) -> float:
        del unit_name
        return 2.0


def job(name: str) -> BackupJob:
    return BackupJob(backup_job=name, backup_title=name, phase="local", unit=f"{name}.service")


class Publication:
    def __init__(self, root: Path) -> None:
        self.state = root / "state"
        self.metrics = root / "backups.prom"
        self.store = FileMetricsStore(self.state, self.metrics)

    def configure(self, *jobs: BackupJob) -> None:
        configure(JobsConfig(jobs=jobs), self.store)

    def record(self, name: str) -> None:
        record(
            name,
            self.store,
            Outcome("success", "exited", "0"),
            FixedDuration(),
            now=100,
        )

    def samples(self, name: str) -> list[Sample]:
        return [
            sample
            for family in text_string_to_metric_families(self.metrics.read_text(encoding="utf-8"))
            for sample in family.samples
            if sample.name == f"host_observability_backup_{name}"
        ]


def test_removal_republishes_saved_outcomes_and_ignores_late_completion(tmp_path: Path) -> None:
    publication = Publication(tmp_path)
    publication.configure(job("retired"), job("kept"))
    publication.record("retired")
    publication.record("kept")

    publication.configure(job("kept"))
    publication.record("retired")

    successes = publication.samples("last_success_timestamp_seconds")
    assert [(sample.labels["backup_job"], sample.value) for sample in successes] == [("kept", 100)]
    assert publication.store.read("retired") is not None


def test_removing_last_job_clears_all_samples(tmp_path: Path) -> None:
    publication = Publication(tmp_path)
    publication.configure(job("retired"))
    publication.record("retired")
    publication.configure()
    publication.record("retired")

    assert publication.samples("job_configured") == []
    assert publication.samples("last_success_timestamp_seconds") == []


def test_reconfiguration_uses_current_labels_and_preserves_success(tmp_path: Path) -> None:
    publication = Publication(tmp_path)
    publication.configure(job("kept"))
    publication.record("kept")
    publication.configure(job("kept").model_copy(update={"backup_title": "Renamed backup"}))

    (success,) = publication.samples("last_success_timestamp_seconds")
    assert success.labels["backup_title"] == "Renamed backup"
    assert success.value == 100


def test_missing_or_corrupt_state_does_not_fabricate_success(tmp_path: Path) -> None:
    publication = Publication(tmp_path)
    publication.configure(job("missing"), job("corrupt"))
    publication.store.state_path("corrupt").write_text("invalid", encoding="utf-8")
    publication.configure(job("missing"), job("corrupt"))

    assert len(publication.samples("job_configured")) == 2
    assert publication.samples("last_success_timestamp_seconds") == []


def test_concurrent_completions_preserve_every_outcome(tmp_path: Path) -> None:
    publication = Publication(tmp_path)
    names = [f"job-{index}" for index in range(20)]
    publication.configure(*(job(name) for name in names))

    with ThreadPoolExecutor(max_workers=8) as executor:
        list(executor.map(publication.record, names))

    successes = publication.samples("last_success_timestamp_seconds")
    assert {sample.labels["backup_job"] for sample in successes} == set(names)
    assert all(sample.value == 100 for sample in successes)


def test_failed_publication_preserves_outcome_for_recovery(tmp_path: Path) -> None:
    publication = Publication(tmp_path)
    publication.configure(job("kept"))
    publication.metrics.unlink()
    publication.metrics.mkdir()

    with pytest.raises(IsADirectoryError):
        publication.record("kept")

    publication.metrics.rmdir()
    publication.configure(job("kept"))
    (success,) = publication.samples("last_success_timestamp_seconds")
    assert success.value == 100
