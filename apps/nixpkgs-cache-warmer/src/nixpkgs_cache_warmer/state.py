from __future__ import annotations

import json
import shlex
from datetime import datetime
from pathlib import Path
from typing import Literal

from atomic_file_writes import write_text_atomic
from pydantic import ValidationError

from nixpkgs_cache_warmer.commands import CommandError
from nixpkgs_cache_warmer.commands import CommandRunner
from nixpkgs_cache_warmer.models import RunRecord, TargetState, WarmerState
from nixpkgs_cache_warmer.warmer import WarmOutcome


class StateStore:
    def __init__(self, path: Path, metrics_path: Path | None = None) -> None:
        self.path = path
        self._metrics_path = metrics_path

    def read(self) -> WarmerState:
        try:
            content = self.path.read_text(encoding="utf-8")
        except FileNotFoundError:
            return WarmerState()
        except OSError as error:
            raise CommandError(f"failed to read warmer state {self.path}: {error}") from error
        return parse_state(content, str(self.path))

    def write(self, state: WarmerState) -> None:
        content = json.dumps(state.model_dump(mode="json"), indent=2, sort_keys=True) + "\n"
        try:
            write_text_atomic(self.path, content, mode=0o644)
        except OSError as error:
            raise CommandError(f"failed to write warmer state {self.path}: {error}") from error
        if self._metrics_path is not None:
            try:
                write_text_atomic(self._metrics_path, render_metrics(state), mode=0o644)
            except OSError as error:
                raise CommandError(
                    f"failed to write warmer metrics {self._metrics_path}: {error}"
                ) from error


class RemoteStateReader:
    def __init__(self, runner: CommandRunner, ssh: Path, host: str, path: Path) -> None:
        self._runner = runner
        self._ssh = ssh
        self._host = host
        self._path = path

    def read(self) -> WarmerState:
        remote_command = shlex.join(("/bin/cat", str(self._path)))
        result = self._runner.run((str(self._ssh), self._host, remote_command))
        if result.returncode != 0:
            detail = result.stderr.strip() or f"exit status {result.returncode}"
            raise CommandError(f"failed to read warmer state from {self._host}: {detail}")
        return parse_state(result.stdout, f"{self._host}:{self._path}")


def parse_state(content: str, source: str) -> WarmerState:
    try:
        return WarmerState.model_validate_json(content)
    except ValidationError as error:
        raise CommandError(f"invalid warmer state {source}: {error}") from error


def render_metrics(state: WarmerState) -> str:
    lines = [
        "# HELP host_observability_nixpkgs_cache_warmer_last_attempt_success Whether the last target attempt completed operationally.",
        "# TYPE host_observability_nixpkgs_cache_warmer_last_attempt_success gauge",
        "# HELP host_observability_nixpkgs_cache_warmer_last_attempt_timestamp_seconds Unix timestamp of the last target attempt.",
        "# TYPE host_observability_nixpkgs_cache_warmer_last_attempt_timestamp_seconds gauge",
        "# HELP host_observability_nixpkgs_cache_warmer_last_success_timestamp_seconds Unix timestamp of the last operationally successful target run.",
        "# TYPE host_observability_nixpkgs_cache_warmer_last_success_timestamp_seconds gauge",
        "# HELP host_observability_nixpkgs_cache_warmer_last_success_revision_info Exact nixpkgs revision from the last operationally successful target run.",
        "# TYPE host_observability_nixpkgs_cache_warmer_last_success_revision_info gauge",
    ]
    for target in state.targets:
        labels = _metric_labels(target.reference, target.system)
        lines.append(
            "host_observability_nixpkgs_cache_warmer_last_attempt_success"
            f"{{{labels}}} {int(target.last_attempt.status != 'failed')}"
        )
        lines.append(
            "host_observability_nixpkgs_cache_warmer_last_attempt_timestamp_seconds"
            f"{{{labels}}} {target.last_attempt.attempted_at.timestamp():.0f}"
        )
        if target.last_success is not None:
            lines.append(
                "host_observability_nixpkgs_cache_warmer_last_success_timestamp_seconds"
                f"{{{labels}}} {target.last_success.attempted_at.timestamp():.0f}"
            )
            revision = _escape_metric_label(target.last_success.revision or "")
            lines.append(
                "host_observability_nixpkgs_cache_warmer_last_success_revision_info"
                f'{{{labels},revision="{revision}"}} 1'
            )
    return "\n".join(lines) + "\n"


def _metric_labels(reference: str, system: str) -> str:
    branch = _escape_metric_label(reference.rsplit("/", 1)[-1])
    escaped_system = _escape_metric_label(system)
    return f'branch="{branch}",system="{escaped_system}"'


def _escape_metric_label(value: str) -> str:
    return value.replace("\\", "\\\\").replace("\n", "\\n").replace('"', '\\"')


def completed_record(outcome: WarmOutcome, now: datetime) -> RunRecord:
    selected = len(outcome.build.successful) + len(outcome.build.failed)
    status: Literal["success", "partial"] = "success" if not outcome.build.failed else "partial"
    error = None
    if outcome.build.failed:
        error = "failed packages: " + ", ".join(target.pname for target in outcome.build.failed)
    return RunRecord(
        attempted_at=now,
        revision=outcome.resolved.revision,
        status=status,
        selected=selected,
        built=len(outcome.build.successful),
        failed=len(outcome.build.failed),
        pushed=len(outcome.build.outputs) if outcome.published_caches else 0,
        error=error,
    )


def failed_record(now: datetime, error: str) -> RunRecord:
    return RunRecord(
        attempted_at=now,
        revision=None,
        status="failed",
        selected=0,
        built=0,
        failed=0,
        pushed=0,
        error=error,
    )


def update_state(
    state: WarmerState,
    reference: str,
    system: str,
    record: RunRecord,
) -> WarmerState:
    existing = next(
        (
            target
            for target in state.targets
            if target.reference == reference and target.system == system
        ),
        None,
    )
    last_success = record if record.status != "failed" else None
    if existing is not None and last_success is None:
        last_success = existing.last_success
    updated = TargetState(
        reference=reference,
        system=system,
        last_attempt=record,
        last_success=last_success,
    )
    targets = [
        target
        for target in state.targets
        if target.reference != reference or target.system != system
    ]
    targets.append(updated)
    targets.sort(key=lambda target: (target.reference, target.system))
    return WarmerState(targets=tuple(targets))
