from __future__ import annotations

import argparse
import os
import sys
import time
from collections.abc import Mapping, Sequence
from pathlib import Path

from .models import JobsConfig, Outcome
from .service import configure, record
from .storage import FileMetricsStore
from .systemd import DurationSource, SystemdDurationSource


def configure_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Export configured backup jobs")
    parser.add_argument("--config", required=True)
    parser.add_argument("--state-directory", required=True)
    parser.add_argument("--metrics-file", required=True)
    return parser


def record_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Record a backup service outcome")
    parser.add_argument("--backup-job", required=True)
    parser.add_argument("--state-directory", required=True)
    parser.add_argument("--metrics-file", required=True)
    return parser


def run_configure(arguments: Sequence[str]) -> None:
    args = configure_parser().parse_args(arguments)
    configuration = JobsConfig.model_validate_json(Path(args.config).read_text(encoding="utf-8"))
    configure(configuration, FileMetricsStore(Path(args.state_directory), Path(args.metrics_file)))


def run_record(
    arguments: Sequence[str],
    environment: Mapping[str, str],
    duration_source: DurationSource,
    *,
    now: float,
) -> None:
    args = record_parser().parse_args(arguments)
    outcome = Outcome(
        service_result=environment.get("SERVICE_RESULT", "unknown"),
        exit_code=environment.get("EXIT_CODE", "unknown"),
        exit_status=environment.get("EXIT_STATUS", "unknown"),
    )
    record(
        str(args.backup_job),
        FileMetricsStore(Path(args.state_directory), Path(args.metrics_file)),
        outcome,
        duration_source,
        now=now,
    )


def configure_main() -> None:
    run_configure(sys.argv[1:])


def record_main() -> None:
    run_record(sys.argv[1:], os.environ, SystemdDurationSource(), now=time.time())
