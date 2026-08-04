from __future__ import annotations

import time
from dataclasses import dataclass
from typing import Protocol

from .clients import BucketUsageClient, RepositoryUsageClient
from .errors import CollectionFailure
from .models import (
    BucketState,
    ExporterConfig,
    ExporterState,
    RepositoryConfig,
    RepositoryState,
)


class Clock(Protocol):
    def now(self) -> float: ...

    def monotonic(self) -> float: ...


@dataclass(frozen=True)
class SystemClock:
    def now(self) -> float:
        return time.time()

    def monotonic(self) -> float:
        return time.monotonic()


@dataclass(frozen=True)
class UsageCollector:
    buckets: BucketUsageClient
    repositories: RepositoryUsageClient
    clock: Clock

    def collect(self, config: ExporterConfig, previous: ExporterState) -> ExporterState:
        bucket_states = {
            name: self._collect_bucket(name, previous.buckets.get(name, BucketState()))
            for name in config.buckets
        }
        repository_states = {
            repository.name: self._collect_repository(
                repository,
                previous.repositories.get(repository.name, RepositoryState()),
            )
            for repository in config.repositories
        }
        return ExporterState(buckets=bucket_states, repositories=repository_states)

    def _collect_bucket(self, name: str, previous: BucketState) -> BucketState:
        now = self.clock.now()
        start = self.clock.monotonic()
        try:
            usage = self.buckets.usage(name)
        except CollectionFailure as failure:
            return previous.model_copy(
                update={
                    "last_run_timestamp_seconds": now,
                    "last_duration_seconds": self.clock.monotonic() - start,
                    "last_success": 0,
                    "exit_code": failure.exit_code,
                }
            )
        return BucketState(
            total_size_bytes=usage.total_size_bytes,
            file_count=usage.file_count,
            last_run_timestamp_seconds=now,
            last_success_timestamp_seconds=now,
            last_duration_seconds=self.clock.monotonic() - start,
            last_success=1,
            exit_code=0,
        )

    def _collect_repository(
        self,
        repository: RepositoryConfig,
        previous: RepositoryState,
    ) -> RepositoryState:
        now = self.clock.now()
        start = self.clock.monotonic()
        try:
            stats = self.repositories.stats(repository)
        except CollectionFailure as failure:
            return previous.model_copy(
                update={
                    "last_run_timestamp_seconds": now,
                    "last_duration_seconds": self.clock.monotonic() - start,
                    "last_success": 0,
                    "exit_code": failure.exit_code,
                }
            )
        return RepositoryState(
            total_size_bytes=stats.total_size,
            total_uncompressed_size_bytes=stats.total_uncompressed_size,
            total_blob_count=stats.total_blob_count,
            snapshots_count=stats.snapshots_count,
            last_run_timestamp_seconds=now,
            last_success_timestamp_seconds=now,
            last_duration_seconds=self.clock.monotonic() - start,
            last_success=1,
            exit_code=0,
        )
