from __future__ import annotations

import os
import shutil
import time
from pathlib import Path
from typing import Callable

from .errors import CueSplitterError, ManualMatchRequired, NeedsAttention, SourceInvalid
from .lidarr import Lidarr
from .media import (
    STAGING_DIR_NAME,
    MediaRunner,
    build_manual_import_files,
    cue_already_split_audio_files,
    inspection_summary,
    is_within,
    safe_component,
    source_fingerprint,
)
from .models import CueSummary, QueueRecord
from .state import Job, StateStore


TERMINAL_COMMAND_STATES = {"completed", "failed", "aborted", "cancelled", "orphaned"}


class CueProcessor:
    """Discover, split, verify, and import one completed Lidarr CUE download."""

    def __init__(
        self,
        *,
        runner: MediaRunner,
        store: StateStore,
        allowed_roots: list[Path],
        work_root: Path,
        command_timeout_seconds: float,
        now: Callable[[], float] = time.time,
        sleep: Callable[[float], None] = time.sleep,
    ):
        self.runner = runner
        self.store = store
        self.allowed_roots = [root.resolve() for root in allowed_roots]
        self.work_root = work_root.resolve()
        self.command_timeout_seconds = command_timeout_seconds
        self.now = now
        self.sleep = sleep

    @staticmethod
    def cue_files(output_path: Path) -> list[Path]:
        return sorted(
            path
            for path in output_path.rglob("*")
            if path.is_file()
            and path.suffix.lower() == ".cue"
            and STAGING_DIR_NAME not in path.parts
        )

    def download_is_already_split(self, record: QueueRecord) -> bool:
        if record.output_path is None:
            return False
        output_path = record.output_path
        if not is_within(output_path, self.allowed_roots) or not output_path.is_dir():
            return False
        cues = self.cue_files(output_path)
        if not cues:
            return False
        for cue in cues:
            audio_files = cue_already_split_audio_files(cue)
            if audio_files is None:
                return False
            if not is_within(cue, self.allowed_roots) or any(
                not is_within(path, self.allowed_roots) for path in audio_files
            ):
                return False
        return True

    def discover(self, record: QueueRecord) -> tuple[list[CueSummary], str]:
        if record.output_path is None:
            raise CueSplitterError("Lidarr queue record does not contain an output path")
        output_path = record.output_path
        if not is_within(output_path, self.allowed_roots):
            raise NeedsAttention(f"download path is outside allowed roots: {output_path}")
        if not output_path.is_dir():
            raise CueSplitterError(f"download path does not exist: {output_path}")
        summaries = []
        for cue in self.cue_files(output_path):
            already_split_audio_files = cue_already_split_audio_files(cue)
            if already_split_audio_files is not None:
                if not is_within(cue, self.allowed_roots) or any(
                    not is_within(path, self.allowed_roots) for path in already_split_audio_files
                ):
                    raise NeedsAttention(f"CUE references audio outside allowed roots: {cue}")
                continue
            summary = inspection_summary(cue, self.runner.inspect(cue))
            if not is_within(summary.cue, self.allowed_roots) or any(
                not is_within(path, self.allowed_roots) for path in summary.audio_files
            ):
                raise NeedsAttention(f"CUE references audio outside allowed roots: {cue}")
            if summary.eligible:
                summaries.append(summary)
        return summaries, source_fingerprint(summaries) if summaries else ""

    def prepare(self, record: QueueRecord, job: Job, summaries: list[CueSummary]) -> Path:
        component = safe_component(record.download_id)
        partial_root = self.work_root / f"{component}.partial"
        if record.output_path is None:
            raise CueSplitterError("Lidarr queue record does not contain an output path")
        output_path = record.output_path.resolve()
        ready_root = output_path / STAGING_DIR_NAME / component
        if partial_root.exists():
            shutil.rmtree(partial_root)
        if ready_root.exists():
            shutil.rmtree(ready_root)
        partial_root.mkdir(parents=True)
        generated: list[Path] = []
        expected_tracks = 0
        try:
            job.status = "splitting"
            job.updated_at = self.now()
            self.store.save()
            for index, summary in enumerate(summaries, start=1):
                cue_output = partial_root / f"disc-{index:02d}-{safe_component(summary.cue.stem)}"
                cue_output.mkdir(parents=True)
                generated.extend(self.runner.split(summary.cue, cue_output))
                expected_tracks += summary.track_count
            if len(generated) != expected_tracks:
                raise SourceInvalid(
                    f"unflac generated {len(generated)} tracks; expected {expected_tracks}"
                )
            job.status = "verifying"
            job.updated_at = self.now()
            self.store.save()
            for path in generated:
                self.runner.verify_flac(path)
            ready_root.parent.mkdir(parents=True, exist_ok=True)
            os.replace(partial_root, ready_root)
            generated = sorted(path.resolve() for path in ready_root.rglob("*.flac"))
            job.status = "matching"
            job.ready_root = ready_root
            job.tracks = len(generated)
            job.updated_at = self.now()
            self.store.save()
            return ready_root
        except Exception:
            if partial_root.exists():
                shutil.rmtree(partial_root)
            raise

    def import_result(
        self,
        client: Lidarr,
        record: QueueRecord,
        job: Job,
        ready_root: Path,
    ) -> None:
        generated = sorted(path.resolve() for path in ready_root.rglob("*.flac"))
        try:
            outputs = client.manual_import(ready_root, record)
            import_files = build_manual_import_files(outputs, generated, record)
            job.status = "importing"
            job.updated_at = self.now()
            self.store.save()
            command_id = client.submit_manual_import(import_files)
            job.command_id = command_id
            deadline = time.monotonic() + self.command_timeout_seconds
            while time.monotonic() < deadline:
                command = client.command(command_id)
                status = command.status.lower()
                if status in TERMINAL_COMMAND_STATES:
                    if status != "completed":
                        raise ManualMatchRequired(
                            f"Lidarr manual-import command {command_id} ended as {status}: "
                            f"{command.message}"
                        )
                    break
                self.sleep(2.0)
            else:
                raise ManualMatchRequired(f"Lidarr manual-import command {command_id} timed out")
        except ManualMatchRequired:
            raise
        except CueSplitterError as exc:
            raise ManualMatchRequired(
                f"Lidarr could not import the generated tracks: {exc}"
            ) from exc
        except Exception as exc:
            raise NeedsAttention(
                f"unexpected failure after splitting; generated tracks were preserved: {exc}"
            ) from exc
        job.status = "awaiting_queue_removal"
        job.updated_at = self.now()
        job.error = ""
        self.store.save()

    def cleanup(self, ready_root: Path) -> None:
        if STAGING_DIR_NAME not in ready_root.parts or not is_within(
            ready_root, self.allowed_roots
        ):
            raise NeedsAttention(f"refusing to clean unsafe staging path: {ready_root}")
        if ready_root.exists():
            shutil.rmtree(ready_root)
        parent = ready_root.parent
        if parent.exists() and not any(parent.iterdir()):
            parent.rmdir()
