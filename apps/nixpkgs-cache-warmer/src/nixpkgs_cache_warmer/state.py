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
    def __init__(self, path: Path) -> None:
        self.path = path

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
    last_success = record if record.status == "success" else None
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
