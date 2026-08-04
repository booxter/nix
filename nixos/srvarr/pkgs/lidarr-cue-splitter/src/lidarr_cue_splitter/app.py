from __future__ import annotations

import argparse
import hashlib
import logging
import os
import re
import shutil
import subprocess
import sys
import time
import xml.etree.ElementTree as ET
from collections import Counter
from pathlib import Path
from typing import Callable

from pydantic import TypeAdapter, ValidationError

from .errors import CueSplitterError, ManualMatchRequired, NeedsAttention, SourceInvalid
from .files import atomic_write
from .lidarr import Lidarr, LidarrClient
from .models import (
    CueSummary,
    ManualImportCandidate,
    ManualImportFile,
    QueueRecord,
    UnflacInput,
)
from .state import EXPIRING_JOB_STATES, Job, StateStore


LOG = logging.getLogger("lidarr-cue-splitter")
STAGING_DIR_NAME = "_lidarr-cue-split"
SUPPORTED_PROTOCOLS = {
    "torrent",
    "torrentdownloadprotocol",
    "usenet",
    "usenetdownloadprotocol",
}
TERMINAL_COMMAND_STATES = {"completed", "failed", "aborted", "cancelled", "orphaned"}
MAX_SOURCE_ATTEMPTS = 3
SOURCE_RETRY_SECONDS = 300
MISSING_QUEUE_CONFIRMATIONS = 3
ACTIVE_JOB_STATES = {
    "settling",
    "splitting",
    "verifying",
    "matching",
    "importing",
    "awaiting_queue_removal",
}
PROCESSING_JOB_STATES = {"splitting", "verifying", "matching", "importing"}
PROBLEM_JOB_STATES = {"failed", "automation_failed", "needs_attention"}
KNOWN_JOB_STATES = (
    ACTIVE_JOB_STATES
    | EXPIRING_JOB_STATES
    | {
        "automation_failed",
        "awaiting_manual_match",
        "failed",
        "needs_attention",
    }
)
AUDIO_FILE_SUFFIXES = {
    ".aac",
    ".aif",
    ".aiff",
    ".alac",
    ".ape",
    ".dff",
    ".dsf",
    ".flac",
    ".m4a",
    ".mka",
    ".mp3",
    ".mpc",
    ".ogg",
    ".opus",
    ".tak",
    ".tta",
    ".wav",
    ".wave",
    ".wma",
    ".wv",
}
CUE_FILE_COMMAND_RE = re.compile(r'^\s*FILE\s+(?:"([^"]+)"|(\S+))\s+\S+', re.IGNORECASE)
CUE_TRACK_COMMAND_RE = re.compile(r"^\s*TRACK\s+\d+\s+\S+", re.IGNORECASE)
UNFLAC_INSPECTIONS = TypeAdapter(list[UnflacInput])


def is_within(path: Path, roots: list[Path]) -> bool:
    resolved = path.resolve()
    return any(
        resolved == root.resolve() or resolved.is_relative_to(root.resolve()) for root in roots
    )


def safe_component(value: str) -> str:
    readable = re.sub(r"[^A-Za-z0-9._-]+", "-", value).strip("-.")[:48] or "download"
    digest = hashlib.sha256(value.encode()).hexdigest()[:12]
    return f"{readable}-{digest}"


def resolve_cue_audio_reference(cue: Path, reference: str) -> Path | None:
    referenced = Path(reference)
    candidate = referenced if referenced.is_absolute() else cue.parent / referenced
    try:
        if candidate.is_file():
            return candidate.resolve()
        matches = sorted(
            path.resolve()
            for path in candidate.parent.iterdir()
            if path.is_file()
            and path.stem == candidate.stem
            and path.suffix.lower() in AUDIO_FILE_SUFFIXES
        )
    except (OSError, RuntimeError):
        return None
    return matches[0] if len(matches) == 1 else None


def cue_already_split_audio_files(cue: Path) -> list[Path] | None:
    try:
        content = cue.read_bytes().decode("utf-8-sig", errors="surrogateescape")
    except OSError:
        return None

    references: list[str] = []
    track_count = 0
    for line in content.splitlines():
        file_match = CUE_FILE_COMMAND_RE.match(line)
        if file_match:
            references.append(file_match.group(1) or file_match.group(2))
        if CUE_TRACK_COMMAND_RE.match(line):
            track_count += 1

    if not references or len(references) != track_count:
        return None
    audio_files: list[Path] = []
    for reference in references:
        audio_file = resolve_cue_audio_reference(cue, reference)
        if audio_file is None:
            return None
        audio_files.append(audio_file)
    if len(set(audio_files)) != track_count:
        return None
    return audio_files


def read_api_key(config_path: Path) -> str:
    try:
        root = ET.parse(config_path).getroot()
    except (OSError, ET.ParseError) as exc:
        raise CueSplitterError(f"cannot read Lidarr config {config_path}: {exc}") from exc
    api_key = (root.findtext("ApiKey") or "").strip()
    if not api_key:
        raise CueSplitterError(f"Lidarr config {config_path} does not contain ApiKey")
    return api_key


class UnflacRunner:
    def __init__(self, run: Callable[..., subprocess.CompletedProcess[str]] = subprocess.run):
        self.run = run

    def inspect(self, cue: Path) -> list[UnflacInput]:
        result = self.run(
            ["unflac", "-d", "-j", str(cue)],
            check=False,
            capture_output=True,
            text=True,
            errors="replace",
        )
        if result.returncode != 0:
            raise SourceInvalid(f"unflac could not parse {cue}: {result.stderr.strip()}")
        try:
            payload = UNFLAC_INSPECTIONS.validate_json(result.stdout)
        except ValidationError as exc:
            raise SourceInvalid(f"unflac returned invalid inspection JSON for {cue}") from exc
        if not payload:
            raise SourceInvalid(f"unflac found no input in {cue}")
        return payload

    def split(self, cue: Path, output_dir: Path) -> list[Path]:
        result = self.run(
            ["unflac", "-f", "flac", "-o", str(output_dir), str(cue)],
            check=False,
            capture_output=True,
            text=True,
            errors="replace",
        )
        if result.returncode != 0:
            raise SourceInvalid(f"unflac failed for {cue}: {result.stderr.strip()}")
        return sorted(path.resolve() for path in output_dir.rglob("*.flac") if path.is_file())

    def verify_flac(self, path: Path) -> None:
        result = self.run(
            ["flac", "--silent", "--test", str(path)],
            check=False,
            capture_output=True,
            text=True,
            errors="replace",
        )
        if result.returncode != 0:
            raise SourceInvalid(f"FLAC verification failed for {path}: {result.stderr.strip()}")


def inspection_summary(cue: Path, payload: list[UnflacInput]) -> CueSummary:
    audio_files: list[Path] = []
    track_count = 0
    has_image = False
    for item in payload:
        for audio in item.audio:
            path = audio.path
            if not path.is_absolute():
                path = cue.parent / path
            audio_files.append(path.resolve())
            track_count += len(audio.tracks)
            has_image = has_image or len(audio.tracks) > 1
    if not audio_files or track_count == 0:
        raise SourceInvalid(f"unflac inspection found no audio tracks for {cue}")
    return CueSummary(
        cue=cue.resolve(),
        audio_files=tuple(audio_files),
        track_count=track_count,
        eligible=has_image,
    )


def source_fingerprint(summaries: list[CueSummary]) -> str:
    entries: list[str] = []
    paths: set[Path] = set()
    for summary in summaries:
        paths.add(summary.cue)
        paths.update(summary.audio_files)
    for path in sorted(paths):
        stat = path.stat()
        entries.append(f"{path}\0{stat.st_size}\0{stat.st_mtime_ns}")
    return hashlib.sha256("\n".join(entries).encode()).hexdigest()


def output_fingerprint(output_path: Path) -> str:
    if not output_path.is_dir():
        return f"missing:{output_path}"
    entries: list[str] = []
    try:
        for path in sorted(output_path.rglob("*")):
            if (
                not path.is_file()
                or STAGING_DIR_NAME in path.parts
                or (
                    path.suffix.lower() != ".cue" and path.suffix.lower() not in AUDIO_FILE_SUFFIXES
                )
            ):
                continue
            stat = path.stat()
            entries.append(f"{path.relative_to(output_path)}\0{stat.st_size}\0{stat.st_mtime_ns}")
    except OSError as exc:
        return f"unreadable:{output_path}:{exc}"
    return hashlib.sha256("\n".join(entries).encode()).hexdigest()


def build_manual_import_files(
    outputs: list[ManualImportCandidate],
    generated_files: list[Path],
    record: QueueRecord,
) -> list[ManualImportFile]:
    generated = {path.resolve() for path in generated_files}
    selected: dict[Path, ManualImportFile] = {}
    expected_artist = record.artist_id
    expected_album = record.album_id
    for output in outputs:
        path = output.path.resolve()
        if path not in generated:
            continue
        if output.rejections:
            reasons = "; ".join(item.reason for item in output.rejections)
            raise ManualMatchRequired(f"Lidarr rejected {path.name}: {reasons}")
        artist_id = output.artist.id
        album_id = output.album.id
        if expected_artist and artist_id != expected_artist:
            raise ManualMatchRequired(
                f"Lidarr matched {path.name} to artist {artist_id}, expected {expected_artist}"
            )
        if expected_album and album_id != expected_album:
            raise ManualMatchRequired(
                f"Lidarr matched {path.name} to album {album_id}, expected {expected_album}"
            )
        track_ids = [track.id for track in output.tracks if track.id]
        if not track_ids:
            raise ManualMatchRequired(f"Lidarr did not match {path.name} to a track")
        selected[path] = ManualImportFile(
            path=path,
            artist_id=artist_id,
            album_id=album_id,
            album_release_id=output.album_release_id,
            track_ids=track_ids,
            quality=output.quality,
            download_id=output.download_id or record.download_id,
            disable_release_switching=output.disable_release_switching,
        )
    missing = generated - selected.keys()
    if missing:
        names = ", ".join(sorted(path.name for path in missing))
        raise ManualMatchRequired(f"Lidarr did not return every generated track: {names}")
    return [selected[path] for path in sorted(selected)]


def prometheus_metrics(store: StateStore, ok: bool, now: float) -> str:
    states = Counter(job.status for job in store.state.jobs.values())
    totals = store.state.totals
    lines = [
        "# HELP host_observability_lidarr_cue_splitter_ok Whether the latest service iteration completed successfully.",
        "# TYPE host_observability_lidarr_cue_splitter_ok gauge",
        f"host_observability_lidarr_cue_splitter_ok {1 if ok else 0}",
        "# HELP host_observability_lidarr_cue_splitter_last_run_timestamp_seconds Unix timestamp of the latest iteration.",
        "# TYPE host_observability_lidarr_cue_splitter_last_run_timestamp_seconds gauge",
        f"host_observability_lidarr_cue_splitter_last_run_timestamp_seconds {now}",
        "# HELP host_observability_lidarr_cue_splitter_active Whether a split or import job is active.",
        "# TYPE host_observability_lidarr_cue_splitter_active gauge",
        f"host_observability_lidarr_cue_splitter_active {1 if any(states[state] for state in ACTIVE_JOB_STATES) else 0}",
        "# HELP host_observability_lidarr_cue_splitter_jobs Number of known jobs by state.",
        "# TYPE host_observability_lidarr_cue_splitter_jobs gauge",
    ]
    for state in sorted(set(states) | KNOWN_JOB_STATES):
        lines.append(
            f'host_observability_lidarr_cue_splitter_jobs{{state="{state}"}} {states[state]}'
        )
    lines.extend(
        [
            "# HELP host_observability_lidarr_cue_splitter_jobs_total Jobs handled by result.",
            "# TYPE host_observability_lidarr_cue_splitter_jobs_total counter",
            f'host_observability_lidarr_cue_splitter_jobs_total{{result="success"}} {totals.success}',
            f'host_observability_lidarr_cue_splitter_jobs_total{{result="failed"}} {totals.failed}',
            f'host_observability_lidarr_cue_splitter_jobs_total{{result="ignored"}} {totals.ignored}',
            f'host_observability_lidarr_cue_splitter_jobs_total{{result="manual"}} {totals.manual}',
            f'host_observability_lidarr_cue_splitter_jobs_total{{result="source_invalid"}} {totals.source_invalid}',
            f'host_observability_lidarr_cue_splitter_jobs_total{{result="source_unavailable"}} {totals.source_unavailable}',
            "# HELP host_observability_lidarr_cue_splitter_tracks_total Tracks generated by successful jobs.",
            "# TYPE host_observability_lidarr_cue_splitter_tracks_total counter",
            f"host_observability_lidarr_cue_splitter_tracks_total {totals.tracks}",
            "# HELP host_observability_lidarr_cue_splitter_last_job_duration_seconds Duration of the latest successful job.",
            "# TYPE host_observability_lidarr_cue_splitter_last_job_duration_seconds gauge",
            f"host_observability_lidarr_cue_splitter_last_job_duration_seconds {store.state.last_duration}",
        ]
    )
    if store.state.last_success is not None:
        lines.extend(
            [
                "# HELP host_observability_lidarr_cue_splitter_last_success_timestamp_seconds Unix timestamp of the latest successful import.",
                "# TYPE host_observability_lidarr_cue_splitter_last_success_timestamp_seconds gauge",
                f"host_observability_lidarr_cue_splitter_last_success_timestamp_seconds {store.state.last_success}",
            ]
        )
    return "\n".join(lines) + "\n"


class CueSplitterService:
    def __init__(
        self,
        *,
        client_factory: Callable[[], Lidarr],
        runner: UnflacRunner,
        store: StateStore,
        allowed_roots: list[Path],
        work_root: Path,
        metrics_file: Path,
        settle_seconds: float,
        command_timeout_seconds: float,
        missing_queue_confirmations: int = MISSING_QUEUE_CONFIRMATIONS,
        now: Callable[[], float] = time.time,
        sleep: Callable[[float], None] = time.sleep,
    ):
        self.client_factory = client_factory
        self.runner = runner
        self.store = store
        self.allowed_roots = [root.resolve() for root in allowed_roots]
        self.work_root = work_root.resolve()
        self.metrics_file = metrics_file
        self.settle_seconds = settle_seconds
        self.command_timeout_seconds = command_timeout_seconds
        self.missing_queue_confirmations = missing_queue_confirmations
        self.now = now
        self.sleep = sleep

    @staticmethod
    def completed_record(record: QueueRecord) -> bool:
        return (
            record.status.lower() == "completed"
            and record.protocol.lower() in SUPPORTED_PROTOCOLS
            and bool(record.download_id)
            and record.output_path is not None
        )

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
        cues = self.cue_files(output_path)
        summaries = []
        for cue in cues:
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

    def prepare_split(
        self,
        record: QueueRecord,
        job: Job,
        summaries: list[CueSummary],
    ) -> Path:
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

    def import_split(
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
                            f"Lidarr manual-import command {command_id} ended as {status}: {command.message}"
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

    def process(self, client: Lidarr, record: QueueRecord, job: Job) -> None:
        summaries, fingerprint = self.discover(record)
        if fingerprint != job.fingerprint:
            job.status = "settling"
            job.fingerprint = fingerprint
            job.discovered_at = self.now()
            job.updated_at = self.now()
            job.attempts = 0
            return
        ready_root = self.prepare_split(record, job, summaries)
        self.import_split(client, record, job, ready_root)

    def mark_manual_match(self, job: Job, error: str, now: float) -> None:
        if job.status != "awaiting_manual_match":
            self.store.state.totals.manual += 1
        job.status = "awaiting_manual_match"
        job.error = error
        job.updated_at = now
        LOG.warning(
            "split tracks await manual Lidarr matching: download_id=%s path=%s error=%s",
            job.download_id,
            job.ready_root or "",
            error,
        )

    def mark_ignored(self, job: Job, now: float) -> None:
        if job.status != "ignored":
            self.store.state.totals.ignored += 1
        job.status = "ignored"
        job.updated_at = now
        job.fingerprint = ""
        job.error = ""

    def mark_automation_failed(self, job: Job, error: str, now: float) -> None:
        job.status = "automation_failed"
        job.error = error
        job.updated_at = now
        LOG.error(
            "cue job automation failed: download_id=%s error=%s",
            job.download_id,
            error,
        )

    @staticmethod
    def legacy_failure_kind(error: str) -> str:
        invalid_markers = (
            "unflac",
            "codec can't decode",
            "FLAC verification failed",
        )
        return (
            "source_invalid"
            if any(marker in error for marker in invalid_markers)
            else "source_unavailable"
        )

    def migrate_legacy_job(self, job: Job, now: float) -> None:
        if job.status != "needs_attention":
            return
        if job.ready_root:
            self.mark_manual_match(job, job.error, now)
        elif job.attempts >= MAX_SOURCE_ATTEMPTS:
            job.status = "failed"
            job.failure_kind = self.legacy_failure_kind(job.error)

    def record_source_failure(
        self,
        job: Job,
        record: QueueRecord,
        error: Exception,
        now: float,
    ) -> None:
        if record.output_path is None:
            raise CueSplitterError("Lidarr queue record does not contain an output path")
        fingerprint = output_fingerprint(record.output_path)
        previous_fingerprint = job.failure_fingerprint
        attempts = job.attempts + 1 if previous_fingerprint in {None, fingerprint} else 1
        job.status = "failed"
        job.error = str(error)
        job.failure_fingerprint = fingerprint
        job.failure_kind = (
            "source_invalid" if isinstance(error, SourceInvalid) else "source_unavailable"
        )
        job.updated_at = now
        job.attempts = attempts
        self.store.state.totals.failed += 1
        LOG.exception("cue job failed: download_id=%s", job.download_id)

    def resolve_source_failure(
        self,
        client: Lidarr,
        record: QueueRecord,
        job: Job,
        now: float,
    ) -> None:
        if self.download_is_already_split(record):
            self.mark_ignored(job, now)
            return
        queue_id = record.id
        if queue_id is None or queue_id <= 0:
            self.mark_automation_failed(
                job, "Lidarr queue record does not contain a numeric id", now
            )
            return
        failure_kind = job.failure_kind or "source_unavailable"
        try:
            client.detach_queue_item(queue_id, blocklist=failure_kind == "source_invalid")
        except CueSplitterError as exc:
            self.mark_automation_failed(
                job, f"could not detach failed release from Lidarr: {exc}", now
            )
            return
        job.status = failure_kind
        job.resolution = "lidarr_queue_detached_download_client_retained"
        job.updated_at = now
        if failure_kind == "source_invalid":
            self.store.state.totals.source_invalid += 1
        else:
            self.store.state.totals.source_unavailable += 1
        LOG.warning(
            "detached failed CUE release from Lidarr while retaining client data: download_id=%s state=%s",
            job.download_id,
            failure_kind,
        )

    def complete_job(self, job: Job, ready_root: Path, started: float) -> None:
        if STAGING_DIR_NAME not in ready_root.parts or not is_within(
            ready_root, self.allowed_roots
        ):
            raise NeedsAttention(f"refusing to clean unsafe staging path: {ready_root}")
        if ready_root.exists():
            shutil.rmtree(ready_root)
        parent = ready_root.parent
        if parent.exists() and not any(parent.iterdir()):
            parent.rmdir()
        finished = self.now()
        job.status = "complete"
        job.updated_at = finished
        job.error = ""
        self.store.state.totals.success += 1
        self.store.state.totals.tracks += job.tracks
        self.store.state.last_success = finished
        self.store.state.last_duration = max(0.0, finished - started)
        LOG.info(
            "completed cue split/import: download_id=%s tracks=%s",
            job.download_id,
            job.tracks,
        )

    def recover_interrupted_jobs(self, now: float) -> None:
        for job in self.store.state.jobs.values():
            status = job.status
            if status not in PROCESSING_JOB_STATES:
                continue
            if status in {"matching", "importing"} and job.ready_root:
                self.mark_manual_match(
                    job,
                    "service restarted after splitting; generated tracks were preserved",
                    now,
                )
                continue
            job.status = "failed"
            job.error = "service restarted while the source was processing"
            job.failure_kind = "source_unavailable"
            job.updated_at = now
            job.attempts += 1

    def missing_queue_confirmed(self, job: Job, queued_download_ids: set[str]) -> bool:
        if job.download_id in queued_download_ids:
            job.missing_queue_observations = 0
            return False
        job.missing_queue_observations += 1
        return job.missing_queue_observations >= self.missing_queue_confirmations

    def reconcile_jobs(self, queued_download_ids: set[str], now: float) -> None:
        for job in self.store.state.jobs.values():
            self.migrate_legacy_job(job, now)
            status = job.status
            if status == "awaiting_queue_removal" and job.download_id in queued_download_ids:
                job.missing_queue_observations = 0
                updated_at = job.updated_at if job.updated_at is not None else now
                if now - updated_at > self.command_timeout_seconds:
                    self.mark_manual_match(
                        job,
                        "Lidarr manual import completed but the download remained in the activity queue",
                        now,
                    )
                continue
            if status not in PROBLEM_JOB_STATES | {
                "awaiting_manual_match",
                "awaiting_queue_removal",
            }:
                continue
            if not self.missing_queue_confirmed(job, queued_download_ids):
                continue
            if status == "awaiting_queue_removal":
                try:
                    if job.ready_root is None:
                        raise NeedsAttention("completed import has no staging path")
                    self.complete_job(
                        job,
                        job.ready_root,
                        job.started_at if job.started_at is not None else now,
                    )
                except NeedsAttention as exc:
                    self.mark_automation_failed(job, str(exc), now)
            elif status == "awaiting_manual_match":
                job.status = "manual_resolved"
                job.updated_at = now
                LOG.info(
                    "manual-match job left the Lidarr queue; preserving generated tracks: download_id=%s path=%s",
                    job.download_id,
                    job.ready_root or "",
                )
            else:
                LOG.info(
                    "dismissing CUE job no longer present in Lidarr queue: download_id=%s",
                    job.download_id,
                )
                job.status = "dismissed"
                job.updated_at = now

    def handle_completed_record(
        self,
        client: Lidarr,
        download_id: str,
        record: QueueRecord,
        now: float,
    ) -> bool:
        jobs = self.store.state.jobs
        job = jobs.get(download_id)
        if job is not None:
            self.migrate_legacy_job(job, now)
            if job.status in {
                "automation_failed",
                "awaiting_manual_match",
                "awaiting_queue_removal",
                "complete",
                "manual_resolved",
                "source_invalid",
                "source_unavailable",
            }:
                return False
            if job.status == "failed":
                if record.output_path is None:
                    return False
                current_fingerprint = output_fingerprint(record.output_path)
                previous_fingerprint = job.failure_fingerprint
                if previous_fingerprint and previous_fingerprint != current_fingerprint:
                    job.attempts = 0
                    job.failure_fingerprint = current_fingerprint
                elif job.attempts >= MAX_SOURCE_ATTEMPTS:
                    self.resolve_source_failure(client, record, job, now)
                    return True
                elif (
                    now - (job.updated_at if job.updated_at is not None else now)
                    < SOURCE_RETRY_SECONDS
                ):
                    return False
        try:
            summaries, fingerprint = self.discover(record)
            if not summaries:
                job = self.store.job(download_id)
                self.mark_ignored(job, now)
                return False
            if job is None or job.fingerprint != fingerprint:
                jobs[download_id] = Job(
                    download_id=download_id,
                    title=record.title,
                    status="settling",
                    fingerprint=fingerprint,
                    discovered_at=now,
                    updated_at=now,
                )
                LOG.info(
                    "discovered CUE image: download_id=%s title=%s",
                    download_id,
                    record.title,
                )
                return True
            discovered_at = job.discovered_at if job.discovered_at is not None else now
            if now - discovered_at < self.settle_seconds:
                return False
            job.started_at = now
            self.process(client, record, job)
        except ManualMatchRequired as exc:
            job = self.store.job(download_id)
            self.mark_manual_match(job, str(exc), now)
        except NeedsAttention as exc:
            job = self.store.job(download_id)
            self.mark_automation_failed(job, str(exc), now)
        except Exception as exc:
            job = self.store.job(download_id, title=record.title)
            self.record_source_failure(job, record, exc, now)
        return True

    def process_completed_records(
        self,
        client: Lidarr,
        completed: dict[str, QueueRecord],
        now: float,
    ) -> None:
        if any(job.status in PROCESSING_JOB_STATES for job in self.store.state.jobs.values()):
            return
        for download_id, record in completed.items():
            if self.handle_completed_record(client, download_id, record, now):
                return

    def iteration(self) -> None:
        now = self.now()
        client = self.client_factory()
        records = client.queue()
        queued_download_ids = {record.download_id for record in records if record.download_id}
        completed = {
            record.download_id: record for record in records if self.completed_record(record)
        }
        self.recover_interrupted_jobs(now)
        self.reconcile_jobs(queued_download_ids, now)
        self.process_completed_records(client, completed, now)
        self.store.prune(now)
        self.store.save()

    def write_metrics(self, ok: bool) -> None:
        atomic_write(self.metrics_file, prometheus_metrics(self.store, ok, self.now()))


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Split completed Lidarr CUE images and import the generated tracks."
    )
    parser.add_argument("--lidarr-url", default="http://127.0.0.1:8686")
    parser.add_argument("--lidarr-config", required=True)
    parser.add_argument("--allowed-root", action="append", required=True)
    parser.add_argument("--work-root", required=True)
    parser.add_argument("--state-file", required=True)
    parser.add_argument("--metrics-file", required=True)
    parser.add_argument("--interval-seconds", type=float, default=30.0)
    parser.add_argument("--settle-seconds", type=float, default=30.0)
    parser.add_argument("--request-timeout-seconds", type=float, default=20.0)
    parser.add_argument("--command-timeout-seconds", type=float, default=900.0)
    parser.add_argument("--once", action="store_true")
    parser.add_argument(
        "--log-level", default="INFO", choices=["DEBUG", "INFO", "WARNING", "ERROR"]
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    logging.basicConfig(
        level=getattr(logging, args.log_level),
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    store = StateStore(Path(args.state_file))

    def client_factory() -> LidarrClient:
        return LidarrClient(
            args.lidarr_url,
            read_api_key(Path(args.lidarr_config)),
            args.request_timeout_seconds,
        )

    service = CueSplitterService(
        client_factory=client_factory,
        runner=UnflacRunner(),
        store=store,
        allowed_roots=[Path(root) for root in args.allowed_root],
        work_root=Path(args.work_root),
        metrics_file=Path(args.metrics_file),
        settle_seconds=args.settle_seconds,
        command_timeout_seconds=args.command_timeout_seconds,
    )
    while True:
        started = time.monotonic()
        ok = True
        try:
            service.iteration()
        except Exception:
            ok = False
            LOG.exception("service iteration failed")
        service.write_metrics(ok)
        if args.once:
            return 0 if ok else 1
        time.sleep(max(0.0, args.interval_seconds - (time.monotonic() - started)))


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("", file=sys.stderr)
        raise SystemExit(0)
