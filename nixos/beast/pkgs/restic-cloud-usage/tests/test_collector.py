from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from restic_cloud_usage.collector import UsageCollector
from restic_cloud_usage.errors import CollectionFailure
from restic_cloud_usage.models import (
    BucketState,
    BucketUsage,
    ExporterConfig,
    ExporterState,
    RepositoryConfig,
    RepositoryState,
    ResticStats,
)


@dataclass
class FixedClock:
    wall: float = 1000
    ticks: tuple[float, ...] = (10, 12, 20, 23)
    index: int = 0

    def now(self) -> float:
        return self.wall

    def monotonic(self) -> float:
        value = self.ticks[self.index]
        self.index += 1
        return value


@dataclass(frozen=True)
class SuccessfulBuckets:
    def usage(self, bucket_name: str) -> BucketUsage:
        assert bucket_name == "backups"
        return BucketUsage(total_size_bytes=100, file_count=7)


@dataclass(frozen=True)
class SuccessfulRepositories:
    def stats(self, repository: RepositoryConfig) -> ResticStats:
        assert repository.name == "srvarr"
        return ResticStats(
            total_size=200,
            total_uncompressed_size=300,
            total_blob_count=8,
            snapshots_count=9,
        )


@dataclass(frozen=True)
class FailedBuckets:
    def usage(self, bucket_name: str) -> BucketUsage:
        raise CollectionFailure(5)


@dataclass(frozen=True)
class FailedRepositories:
    def stats(self, repository: RepositoryConfig) -> ResticStats:
        raise CollectionFailure(17)


def config() -> ExporterConfig:
    return ExporterConfig(
        buckets=("backups",),
        b2ApplicationKeyIdFile=Path("/run/secrets/id"),
        b2ApplicationKeyFile=Path("/run/secrets/key"),
        repositories=(
            RepositoryConfig(
                name="srvarr",
                backupJob="restic-srvarr-cloud-offload",
                backupTitle="srvarr Cloud Offload",
                bucket="backups",
                prefix="hosts/srvarr",
                repository="b2:backups:hosts/srvarr",
                passwordFile=Path("/run/secrets/password"),
            ),
        ),
    )


def test_collects_bucket_and_repository_usage() -> None:
    state = UsageCollector(SuccessfulBuckets(), SuccessfulRepositories(), FixedClock()).collect(
        config(), ExporterState()
    )

    assert state.buckets["backups"] == BucketState(
        total_size_bytes=100,
        file_count=7,
        last_run_timestamp_seconds=1000,
        last_success_timestamp_seconds=1000,
        last_duration_seconds=2,
        last_success=1,
        exit_code=0,
    )
    assert state.repositories["srvarr"] == RepositoryState(
        total_size_bytes=200,
        total_uncompressed_size_bytes=300,
        total_blob_count=8,
        snapshots_count=9,
        last_run_timestamp_seconds=1000,
        last_success_timestamp_seconds=1000,
        last_duration_seconds=3,
        last_success=1,
        exit_code=0,
    )


def test_failures_preserve_last_good_measurements() -> None:
    previous = ExporterState(
        buckets={
            "backups": BucketState(
                total_size_bytes=100,
                file_count=7,
                last_success_timestamp_seconds=900,
                last_success=1,
            )
        },
        repositories={
            "srvarr": RepositoryState(
                total_size_bytes=200,
                total_uncompressed_size_bytes=300,
                total_blob_count=8,
                snapshots_count=9,
                last_success_timestamp_seconds=800,
                last_success=1,
            )
        },
    )

    state = UsageCollector(FailedBuckets(), FailedRepositories(), FixedClock()).collect(
        config(), previous
    )

    assert state.buckets["backups"].total_size_bytes == 100
    assert state.buckets["backups"].last_success_timestamp_seconds == 900
    assert state.buckets["backups"].last_success == 0
    assert state.buckets["backups"].exit_code == 5
    assert state.repositories["srvarr"].total_size_bytes == 200
    assert state.repositories["srvarr"].last_success_timestamp_seconds == 800
    assert state.repositories["srvarr"].last_success == 0
    assert state.repositories["srvarr"].exit_code == 17
