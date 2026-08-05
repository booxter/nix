from __future__ import annotations

import argparse
import sys
from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol

from atomic_file_writes import write_text_atomic
from pydantic import ValidationError

from .clients import (
    B2SdkBucketUsageClient,
    ResticRepositoryUsageClient,
    SubprocessRunner,
    restic_environment,
    system_environment,
)
from .collector import SystemClock, UsageCollector
from .metrics import render_metrics
from .models import ExporterConfig, ExporterState


def parser() -> argparse.ArgumentParser:
    command = argparse.ArgumentParser(
        prog="restic-cloud-usage",
        description="Export B2 bucket and restic cloud repository usage metrics.",
    )
    command.add_argument("--config", required=True, type=Path)
    command.add_argument("--state-file", required=True, type=Path)
    command.add_argument("--metrics-file", required=True, type=Path)
    command.add_argument("--restic-cache-dir", required=True)
    command.add_argument("--retry-lock", default="5m")
    return command


def _load_config(path: Path) -> ExporterConfig:
    return ExporterConfig.model_validate_json(path.read_text())


def _load_state(path: Path) -> ExporterState:
    try:
        return ExporterState.model_validate_json(path.read_text())
    except (FileNotFoundError, OSError, ValidationError):
        return ExporterState()


def _read_secret(path: Path) -> str:
    return path.read_text().strip()


class Collector(Protocol):
    def collect(self, config: ExporterConfig, previous: ExporterState) -> ExporterState: ...


class CollectorFactory(Protocol):
    def __call__(
        self,
        *,
        application_key_id: str,
        application_key: str,
        cache_dir: str,
        retry_lock: str,
    ) -> Collector: ...


@dataclass(frozen=True)
class SystemCollectorFactory:
    def __call__(
        self,
        *,
        application_key_id: str,
        application_key: str,
        cache_dir: str,
        retry_lock: str,
    ) -> Collector:
        restic_client = ResticRepositoryUsageClient(
            runner=SubprocessRunner(),
            environment=restic_environment(
                system_environment(),
                application_key_id=application_key_id,
                application_key=application_key,
                cache_dir=cache_dir,
            ),
            cache_dir=cache_dir,
            retry_lock=retry_lock,
        )
        return UsageCollector(
            buckets=B2SdkBucketUsageClient(application_key_id, application_key),
            repositories=restic_client,
            clock=SystemClock(),
        )


def run(
    arguments: argparse.Namespace,
    collector_factory: CollectorFactory = SystemCollectorFactory(),
) -> int:
    config = _load_config(arguments.config)
    application_key_id = _read_secret(config.b2_application_key_id_file)
    application_key = _read_secret(config.b2_application_key_file)
    collector = collector_factory(
        application_key_id=application_key_id,
        application_key=application_key,
        cache_dir=arguments.restic_cache_dir,
        retry_lock=arguments.retry_lock,
    )
    state = collector.collect(config, _load_state(arguments.state_file))
    write_text_atomic(
        arguments.state_file,
        state.model_dump_json(indent=2) + "\n",
        mode=0o644,
    )
    write_text_atomic(
        arguments.metrics_file,
        render_metrics(config, state),
        mode=0o644,
    )
    return 0


def main(argv: Sequence[str] | None = None) -> int:
    arguments = parser().parse_args(argv if argv is not None else sys.argv[1:])
    return run(arguments)
