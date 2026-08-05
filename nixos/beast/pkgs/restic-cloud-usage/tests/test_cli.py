from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from prometheus_client.parser import text_string_to_metric_families

from restic_cloud_usage.cli import Collector, parser, run
from restic_cloud_usage.models import (
    BucketState,
    ExporterConfig,
    ExporterState,
    RepositoryConfig,
    RepositoryState,
)


@dataclass(frozen=True)
class FixedCollector:
    def collect(self, config: ExporterConfig, previous: ExporterState) -> ExporterState:
        assert previous == ExporterState()
        return ExporterState(
            buckets={config.buckets[0]: BucketState(last_success=1)},
            repositories={config.repositories[0].name: RepositoryState(last_success=1)},
        )


@dataclass
class RecordingFactory:
    credentials: tuple[str, str, str, str] | None = None

    def __call__(
        self,
        *,
        application_key_id: str,
        application_key: str,
        cache_dir: str,
        retry_lock: str,
    ) -> Collector:
        self.credentials = (
            application_key_id,
            application_key,
            cache_dir,
            retry_lock,
        )
        return FixedCollector()


def test_run_loads_config_and_writes_state_and_metrics(tmp_path: Path) -> None:
    key_id = tmp_path / "key-id"
    key = tmp_path / "key"
    key_id.write_text(" id\n")
    key.write_text(" key\n")
    config = ExporterConfig(
        buckets=("backups",),
        b2ApplicationKeyIdFile=key_id,
        b2ApplicationKeyFile=key,
        repositories=(
            RepositoryConfig(
                name="srvarr",
                backupJob="restic-srvarr-cloud-offload",
                backupTitle="srvarr Cloud Offload",
                bucket="backups",
                prefix="hosts/srvarr",
                repository="b2:backups:hosts/srvarr",
                passwordFile=tmp_path / "password",
            ),
        ),
    )
    config_path = tmp_path / "config.json"
    state_path = tmp_path / "state.json"
    metrics_path = tmp_path / "usage.prom"
    config_path.write_text(config.model_dump_json(by_alias=True))
    arguments = parser().parse_args(
        [
            "--config",
            str(config_path),
            "--state-file",
            str(state_path),
            "--metrics-file",
            str(metrics_path),
            "--restic-cache-dir",
            "/cache",
        ]
    )
    factory = RecordingFactory()

    assert run(arguments, factory) == 0

    assert factory.credentials == ("id", "key", "/cache", "5m")
    assert (
        ExporterState.model_validate_json(state_path.read_text()).buckets["backups"].last_success
        == 1
    )
    metric_names = {
        sample.name
        for family in text_string_to_metric_families(metrics_path.read_text())
        for sample in family.samples
    }
    assert "host_observability_b2_bucket_total_size_bytes" in metric_names
    assert state_path.stat().st_mode & 0o777 == 0o644
    assert metrics_path.stat().st_mode & 0o777 == 0o644
