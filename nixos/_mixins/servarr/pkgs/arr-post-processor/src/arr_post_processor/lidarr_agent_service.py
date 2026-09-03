from __future__ import annotations

import contextlib
import logging
import shutil
import time
from collections.abc import Callable
from pathlib import Path, PurePosixPath
from uuid import UUID, uuid4

from atomic_file_writes import write_text_atomic
from hermes_runs.client import Client as Hermes
from hermes_runs.client import HermesError, HermesHttpError, RunState, RunStatus

from .audio_probe import AudioVerifier
from .errors import ManualMatchRequired, NeedsAttention, PostProcessorError, SourceInvalid
from .lidarr import Lidarr
from .lidarr_agent_state import (
    ACTIVE_AGENT_STATES,
    FailureKind,
    JobStatus,
    RepairFileState,
    RepairJob,
    RepairStateStore,
    RetainedArtifact,
)
from .lidarr_metrics import render_lidarr_metrics
from .lidarr_repair import (
    REPORT_FILE_NAME,
    RESULT_FILE_NAME,
    LidarrQueueStatus,
    RepairOutcome,
    RepairTask,
    load_repair_result,
    render_repair_instruction,
)
from .models import QueueRecord
from .repair_media import STAGING_DIR_NAME, build_manual_import_files, safe_component
from .repair_source import LocatedSource, SourceRoot, locate_source, source_fingerprint

LOG = logging.getLogger("arr-post-processor.lidarr")
SUPPORTED_PROTOCOLS = {
    "torrent",
    "torrentdownloadprotocol",
    "usenet",
    "usenetdownloadprotocol",
}
MISSING_QUEUE_CONFIRMATIONS = 3
ARTIFACT_RETENTION_SECONDS = 7 * 86400
STOP_GRACE_SECONDS = 300
TERMINAL_COMMAND_STATES = {"completed", "failed", "aborted", "cancelled", "orphaned"}
IGNORED_SOURCE_DIRECTORIES = frozenset({STAGING_DIR_NAME, "_lidarr-cue-split"})


class LidarrAgentService:
    def __init__(
        self,
        *,
        client_factory: Callable[[], Lidarr],
        hermes: Hermes,
        store: RepairStateStore,
        source_roots: tuple[SourceRoot, ...],
        output_root: Path,
        audit_root: Path,
        metrics_file: Path,
        verifier: AudioVerifier,
        settle_seconds: float,
        agent_timeout_seconds: float,
        command_timeout_seconds: float,
        shadow: bool,
        missing_queue_confirmations: int = MISSING_QUEUE_CONFIRMATIONS,
        artifact_retention_seconds: float = ARTIFACT_RETENTION_SECONDS,
        now: Callable[[], float] = time.time,
        uuid_factory: Callable[[], UUID] = uuid4,
    ) -> None:
        self.client_factory = client_factory
        self.hermes = hermes
        self.store = store
        self.source_roots = source_roots
        self.output_root = output_root.resolve()
        self.audit_root = audit_root.resolve()
        self.metrics_file = metrics_file
        self.verifier = verifier
        self.settle_seconds = settle_seconds
        self.agent_timeout_seconds = agent_timeout_seconds
        self.command_timeout_seconds = command_timeout_seconds
        self.shadow = shadow
        self.missing_queue_confirmations = missing_queue_confirmations
        self.artifact_retention_seconds = artifact_retention_seconds
        self.now = now
        self.uuid_factory = uuid_factory

    @staticmethod
    def eligible_record(record: QueueRecord) -> bool:
        return (
            record.status.lower() == "completed"
            and record.tracked_download_status.lower() == "warning"
            and record.protocol.lower() in SUPPORTED_PROTOCOLS
            and record.artist_id > 0
            and record.album_id > 0
            and bool(record.download_id)
            and record.output_path is not None
        )

    def _expected_task_root(self, download_id: str, attempt_id: UUID) -> Path:
        return self.output_root / safe_component(download_id) / str(attempt_id)

    @staticmethod
    def _fingerprint(source: LocatedSource) -> str:
        return source_fingerprint(source, ignored_directories=IGNORED_SOURCE_DIRECTORIES)

    def _retain_task(self, job: RepairJob, now: float) -> None:
        if job.task_root is None or job.attempt_id is None:
            return
        artifact = RetainedArtifact(
            download_id=job.download_id,
            attempt_id=job.attempt_id,
            path=job.task_root,
            expires_at=now + self.artifact_retention_seconds,
        )
        if all(existing.path != artifact.path for existing in self.store.state.retained_artifacts):
            self.store.state.retained_artifacts.append(artifact)
        job.task_root = None
        job.files = []

    def _cleanup_handoff(self, job: RepairJob) -> None:
        if job.handoff_root is None or job.attempt_id is None:
            return
        component = safe_component(job.download_id)
        expected = job.source_path / STAGING_DIR_NAME / component / str(job.attempt_id)
        resolved = job.handoff_root.resolve()
        if resolved != expected.resolve():
            raise NeedsAttention(f"refusing to remove unsafe Lidarr staging: {resolved}")
        if resolved.exists():
            shutil.rmtree(resolved)
        with contextlib.suppress(OSError):
            resolved.parent.rmdir()
        with contextlib.suppress(OSError):
            resolved.parent.parent.rmdir()
        job.handoff_root = None

    def _mark_failure(self, job: RepairJob, kind: FailureKind, error: str, now: float) -> None:
        if job.status is not JobStatus.NEEDS_ATTENTION:
            self.store.state.totals.increment_failure(kind)
        with contextlib.suppress(NeedsAttention):
            self._cleanup_handoff(job)
        self._retain_task(job, now)
        job.status = JobStatus.NEEDS_ATTENTION
        job.failure_kind = kind
        job.pending_failure_kind = None
        job.error = error
        job.updated_at = now
        LOG.warning(
            "Lidarr repair needs attention: download_id=%s kind=%s error=%s",
            job.download_id,
            kind.value,
            error,
        )

    def _mark_manual_resolved(self, job: RepairJob, now: float) -> None:
        if job.status is not JobStatus.MANUAL_RESOLVED:
            self.store.state.totals.manual += 1
        with contextlib.suppress(NeedsAttention):
            self._cleanup_handoff(job)
        self._retain_task(job, now)
        job.status = JobStatus.MANUAL_RESOLVED
        job.updated_at = now
        job.error = ""
        job.failure_kind = None
        job.pending_failure_kind = None
        job.run_id = None

    def _archive_attempt(self, job: RepairJob) -> None:
        if job.task_root is None or job.attempt_id is None:
            raise NeedsAttention("completed repair has no task directory to archive")
        expected = self._expected_task_root(job.download_id, job.attempt_id)
        if job.task_root.resolve() != expected:
            raise NeedsAttention(f"refusing to archive an unsafe task path: {job.task_root}")
        destination = self.audit_root / str(job.attempt_id)
        destination.mkdir(parents=True, exist_ok=True, mode=0o770)
        for name in (REPORT_FILE_NAME, RESULT_FILE_NAME):
            source = expected / name
            if source.is_symlink() or not source.is_file():
                raise NeedsAttention(f"repair audit file is missing or unsafe: {source}")
            target = destination / name
            shutil.copyfile(source, target)
            target.chmod(0o640)

    def _cleanup_task(self, job: RepairJob) -> None:
        if job.task_root is None or job.attempt_id is None:
            raise NeedsAttention("completed repair has no task directory to clean")
        expected = self._expected_task_root(job.download_id, job.attempt_id)
        if job.task_root.resolve() != expected:
            raise NeedsAttention(f"refusing to remove an unsafe task path: {job.task_root}")
        if expected.exists():
            shutil.rmtree(expected)
        with contextlib.suppress(OSError):
            expected.parent.rmdir()
        job.task_root = None
        job.files = []

    def _complete_import(self, job: RepairJob, now: float) -> None:
        track_count = sum(len(item.expected_track_ids) for item in job.files)
        try:
            self._archive_attempt(job)
            self._cleanup_handoff(job)
            self._cleanup_task(job)
        except (OSError, PostProcessorError) as error:
            self._mark_failure(job, FailureKind.IMPORT_FAILED, str(error), now)
            return
        job.status = JobStatus.COMPLETE
        job.updated_at = now
        job.error = ""
        job.failure_kind = None
        job.command_id = None
        self.store.state.totals.success += 1
        self.store.state.totals.tracks += track_count
        self.store.state.last_success = now
        started = job.started_at if job.started_at is not None else now
        self.store.state.last_duration = max(0.0, now - started)
        LOG.info("completed Lidarr Hermes repair/import: download_id=%s", job.download_id)

    def _consume_result(self, job: RepairJob, now: float) -> None:
        if job.task is None or job.task_root is None:
            self._mark_failure(job, FailureKind.INVALID_OUTPUT, "attempt has no task contract", now)
            return
        try:
            validated = load_repair_result(job.task_root, job.task)
            for item in validated.files:
                self.verifier.verify(item.path)
        except (NeedsAttention, SourceInvalid) as error:
            self._mark_failure(job, FailureKind.INVALID_OUTPUT, str(error), now)
            return
        if validated.result.outcome is RepairOutcome.UNRESOLVED:
            self._mark_failure(job, FailureKind.AGENT_UNRESOLVED, validated.result.reason, now)
            return
        job.status = JobStatus.READY
        job.release_id = validated.result.release_id
        job.files = [
            RepairFileState(candidate=item.path, expected_track_ids=list(item.expected_track_ids))
            for item in validated.files
        ]
        job.resolution = validated.result.reason
        job.updated_at = now
        job.error = ""
        job.failure_kind = None

    def _request_stop(
        self,
        job: RepairJob,
        *,
        kind: FailureKind | None,
        error: str,
        now: float,
        dismiss: bool = False,
    ) -> None:
        if job.status is JobStatus.AGENT_STOPPING:
            return
        job.pending_failure_kind = kind
        job.dismiss_requested = dismiss
        job.error = error
        job.updated_at = now
        job.stop_deadline_at = now + STOP_GRACE_SECONDS
        if job.run_id is None:
            if dismiss:
                self._mark_manual_resolved(job, now)
            else:
                self._mark_failure(job, kind or FailureKind.AGENT_START_AMBIGUOUS, error, now)
            return
        job.status = JobStatus.AGENT_STOPPING
        try:
            self.hermes.stop_run(job.run_id)
        except HermesError as stop_error:
            LOG.warning("could not stop Hermes run %s: %s", job.run_id, stop_error)

    def _resolve_stop(self, job: RepairJob, now: float) -> bool:
        if job.dismiss_requested:
            self._mark_manual_resolved(job, now)
            return True
        if job.pending_failure_kind is not None:
            self._mark_failure(job, job.pending_failure_kind, job.error, now)
            return True
        return False

    def _advance_agent(self, job: RepairJob, now: float) -> None:
        if job.status is JobStatus.AGENT_STARTING and job.run_id is None:
            if job.task_root is not None and (job.task_root / RESULT_FILE_NAME).exists():
                self._consume_result(job, now)
            elif job.agent_deadline_at is not None and now >= job.agent_deadline_at:
                self._mark_failure(
                    job,
                    FailureKind.AGENT_START_AMBIGUOUS,
                    "Hermes run start was ambiguous and no result appeared",
                    now,
                )
            return
        if job.run_id is None:
            self._mark_failure(job, FailureKind.AGENT_LOST, "active attempt has no run ID", now)
            return
        if (
            job.status is JobStatus.AGENT_RUNNING
            and job.agent_deadline_at is not None
            and now >= job.agent_deadline_at
        ):
            self._request_stop(
                job, kind=FailureKind.AGENT_TIMED_OUT, error="Hermes repair timed out", now=now
            )
        try:
            status = self.hermes.get_run(job.run_id)
        except HermesHttpError as error:
            if error.status == 404:
                if job.task_root is not None and (job.task_root / RESULT_FILE_NAME).exists():
                    self._consume_result(job, now)
                elif not self._resolve_stop(job, now):
                    self._mark_failure(job, FailureKind.AGENT_LOST, "Hermes lost the run", now)
            else:
                job.error = str(error)
                job.updated_at = now
            return
        except HermesError as error:
            job.error = str(error)
            job.updated_at = now
            if (
                job.stop_deadline_at is not None
                and now >= job.stop_deadline_at
                and not self._resolve_stop(job, now)
            ):
                self._mark_failure(job, FailureKind.AGENT_LOST, str(error), now)
            return
        self._handle_agent_status(job, status, now)

    def _handle_agent_status(self, job: RepairJob, status: RunStatus, now: float) -> None:
        if status.state in {RunState.QUEUED, RunState.RUNNING, RunState.STOPPING}:
            if (
                job.stop_deadline_at is not None
                and now >= job.stop_deadline_at
                and not self._resolve_stop(job, now)
            ):
                self._mark_failure(job, FailureKind.AGENT_LOST, "Hermes did not stop the run", now)
            return
        if status.state is RunState.WAITING_FOR_APPROVAL:
            self._request_stop(
                job,
                kind=FailureKind.APPROVAL_REQUIRED,
                error="Hermes requested approval despite autonomous configuration",
                now=now,
            )
            return
        if self._resolve_stop(job, now):
            return
        if status.state is RunState.COMPLETED:
            self._consume_result(job, now)
        elif status.state is RunState.FAILED:
            self._mark_failure(
                job, FailureKind.AGENT_FAILED, status.error or "Hermes repair failed", now
            )
        else:
            self._mark_failure(job, FailureKind.AGENT_CANCELLED, "Hermes repair was cancelled", now)

    def _advance_existing_jobs(self, client: Lidarr, now: float) -> None:
        for job in self.store.state.jobs.values():
            if job.status in ACTIVE_AGENT_STATES:
                self._advance_agent(job, now)
            elif job.status is JobStatus.IMPORTING:
                self._advance_import(client, job, now)

    def _promote_ready_jobs(
        self,
        client: Lidarr,
        queue: list[QueueRecord],
        ready_at_start: set[str],
        staged_at_start: set[str],
        now: float,
    ) -> None:
        if self.shadow:
            return
        for record in queue:
            ready_job = self.store.state.jobs.get(record.download_id)
            if (
                ready_job is not None
                and record.download_id in ready_at_start
                and ready_job.status is JobStatus.READY
            ):
                self._stage_ready(record, ready_job, now)
                break
        for record in queue:
            staged_job = self.store.state.jobs.get(record.download_id)
            if (
                staged_job is not None
                and record.download_id in staged_at_start
                and staged_job.status is JobStatus.STAGED
            ):
                self._import_staged(client, record, staged_job, now)
                break

    def _start_agent(
        self, client: Lidarr, record: QueueRecord, job: RepairJob, source: LocatedSource, now: float
    ) -> None:
        catalog = client.album_catalog(record.album_id)
        if catalog.album.artist_id != record.artist_id:
            raise NeedsAttention("Lidarr album belongs to a different artist than the queue item")
        attempt_id = self.uuid_factory()
        component = safe_component(record.download_id)
        task_root = self._expected_task_root(record.download_id, attempt_id)
        task_root.parent.mkdir(parents=True, exist_ok=True, mode=0o770)
        task_root.mkdir(mode=0o770)
        task = RepairTask(
            attempt_id=attempt_id,
            download_id=record.download_id,
            source_fingerprint=job.source_fingerprint,
            queue_title=record.title,
            lidarr_queue_status=LidarrQueueStatus(
                status=record.status,
                tracked_download_status=record.tracked_download_status,
                tracked_download_state=record.tracked_download_state,
                messages=record.status_messages,
            ),
            catalog=catalog,
            source_path=str(source.workspace_path),
            output_path=str(PurePosixPath("output", "processed", component, str(attempt_id))),
        )
        job.status = JobStatus.AGENT_STARTING
        job.attempt_id = attempt_id
        job.task = task
        job.task_root = task_root
        job.started_at = now
        job.updated_at = now
        job.agent_deadline_at = now + self.agent_timeout_seconds
        job.error = ""
        self.store.save()
        try:
            job.run_id = self.hermes.start_run(render_repair_instruction(task))
        except HermesError as error:
            job.error = f"Hermes run start failed without a durable run ID: {error}"
            return
        job.status = JobStatus.AGENT_RUNNING
        job.updated_at = now

    def _stage_ready(self, record: QueueRecord, job: RepairJob, now: float) -> None:
        if record.output_path is None or job.attempt_id is None or not job.files:
            self._mark_failure(job, FailureKind.INVALID_OUTPUT, "repair has no files to stage", now)
            return
        try:
            source = locate_source(record.output_path, self.source_roots)
            if self._fingerprint(source) != job.source_fingerprint:
                raise NeedsAttention("Lidarr source changed before repaired tracks were staged")
            component = safe_component(job.download_id)
            staging_parent = source.host_path / STAGING_DIR_NAME / component
            ready_root = staging_parent / str(job.attempt_id)
            partial_root = staging_parent / f"{job.attempt_id}.partial"
            if partial_root.exists():
                shutil.rmtree(partial_root)
            if ready_root.exists():
                shutil.rmtree(ready_root)
            partial_root.mkdir(parents=True, mode=0o770)
            assert job.task_root is not None
            for item in job.files:
                relative = item.candidate.relative_to(job.task_root)
                target = partial_root / relative
                target.parent.mkdir(parents=True, exist_ok=True, mode=0o770)
                shutil.copyfile(item.candidate, target)
                target.chmod(0o640)
                item.staged = ready_root / relative
            partial_root.replace(ready_root)
            job.handoff_root = ready_root
            job.status = JobStatus.STAGED
            job.updated_at = now
        except (OSError, PostProcessorError, ValueError) as error:
            self._mark_failure(job, FailureKind.INVALID_OUTPUT, str(error), now)

    def _import_staged(
        self, client: Lidarr, record: QueueRecord, job: RepairJob, now: float
    ) -> None:
        if job.handoff_root is None or job.release_id is None:
            self._mark_failure(job, FailureKind.IMPORT_FAILED, "staged repair is incomplete", now)
            return
        try:
            staged = tuple(item.staged for item in job.files if item.staged is not None)
            if len(staged) != len(job.files):
                raise NeedsAttention("not every repair candidate has a staged file")
            outputs = client.manual_import(job.handoff_root, record)
            imports = build_manual_import_files(outputs, list(staged), record)
            expected = {
                item.staged.resolve(): set(item.expected_track_ids)
                for item in job.files
                if item.staged is not None
            }
            for item in imports:
                if item.album_release_id != job.release_id:
                    raise ManualMatchRequired("Lidarr selected a different album release")
                if set(item.track_ids) != expected.get(item.path.resolve(), set()):
                    raise ManualMatchRequired(
                        f"Lidarr track mapping disagrees for {item.path.name}"
                    )
                item.disable_release_switching = True
            job.status = JobStatus.IMPORTING
            job.command_id = None
            job.import_deadline_at = now + self.command_timeout_seconds
            job.updated_at = now
            self.store.save()
            job.command_id = client.submit_manual_import(imports)
            job.updated_at = self.now()
        except ManualMatchRequired as error:
            self._mark_failure(job, FailureKind.IMPORT_REJECTED, str(error), now)
        except (NeedsAttention, PostProcessorError) as error:
            self._mark_failure(job, FailureKind.IMPORT_FAILED, str(error), now)

    def _advance_import(self, client: Lidarr, job: RepairJob, now: float) -> None:
        if job.command_id is None:
            self._mark_failure(
                job,
                FailureKind.IMPORT_FAILED,
                "Lidarr import submission outcome is ambiguous after restart",
                now,
            )
            return
        try:
            command = client.command(job.command_id)
        except PostProcessorError as error:
            if job.import_deadline_at is not None and now >= job.import_deadline_at:
                self._mark_failure(job, FailureKind.IMPORT_FAILED, str(error), now)
            return
        status = command.status.lower()
        if status in TERMINAL_COMMAND_STATES:
            if status != "completed":
                self._mark_failure(
                    job,
                    FailureKind.IMPORT_FAILED,
                    f"Lidarr manual-import command ended as {status}: {command.message}",
                    now,
                )
            else:
                job.status = JobStatus.AWAITING_QUEUE_REMOVAL
                job.updated_at = now
                job.error = ""
            return
        if job.import_deadline_at is not None and now >= job.import_deadline_at:
            self._mark_failure(job, FailureKind.IMPORT_FAILED, "Lidarr import timed out", now)

    def _observe_source(self, record: QueueRecord, job: RepairJob, now: float) -> None:
        assert record.output_path is not None
        try:
            fingerprint = self._fingerprint(locate_source(record.output_path, self.source_roots))
        except PostProcessorError as error:
            self._request_stop(job, kind=FailureKind.SOURCE_CHANGED, error=str(error), now=now)
            return
        if fingerprint != job.source_fingerprint:
            self._request_stop(
                job,
                kind=FailureKind.SOURCE_CHANGED,
                error="Lidarr source changed while Hermes was processing it",
                now=now,
            )

    def _reconcile_queue(self, records: dict[str, QueueRecord], now: float) -> None:
        for job in self.store.state.jobs.values():
            record = records.get(job.download_id)
            if record is not None and self.eligible_record(record):
                job.missing_queue_observations = 0
                if job.status in {JobStatus.AGENT_STARTING, JobStatus.AGENT_RUNNING}:
                    self._observe_source(record, job, now)
                continue
            if job.status in {JobStatus.COMPLETE, JobStatus.MANUAL_RESOLVED}:
                continue
            job.missing_queue_observations += 1
            if job.missing_queue_observations < self.missing_queue_confirmations:
                continue
            if job.status in ACTIVE_AGENT_STATES:
                self._request_stop(
                    job,
                    kind=None,
                    error="Lidarr queue item disappeared during repair",
                    now=now,
                    dismiss=True,
                )
            elif job.status is JobStatus.IMPORTING:
                continue
            elif job.status is JobStatus.AWAITING_QUEUE_REMOVAL:
                self._complete_import(job, now)
            else:
                self._mark_manual_resolved(job, now)

    def _record_invalid_source(
        self, record: QueueRecord, error: PostProcessorError, now: float
    ) -> None:
        assert record.output_path is not None
        job = self.store.state.jobs.get(record.download_id)
        if job is None:
            job = RepairJob(
                download_id=record.download_id,
                title=record.title,
                source_path=record.output_path,
                source_fingerprint="",
                discovered_at=now,
                updated_at=now,
            )
            self.store.state.jobs[record.download_id] = job
        self._mark_failure(job, FailureKind.SOURCE_INVALID, str(error), now)

    def _discover_attempt(self, client: Lidarr, queue: list[QueueRecord], now: float) -> None:
        if any(job.status in ACTIVE_AGENT_STATES for job in self.store.state.jobs.values()):
            return
        for record in queue:
            if not self.eligible_record(record):
                continue
            assert record.output_path is not None
            try:
                source = locate_source(record.output_path, self.source_roots)
                fingerprint = self._fingerprint(source)
            except PostProcessorError as error:
                self._record_invalid_source(record, error, now)
                continue
            job = self.store.state.jobs.get(record.download_id)
            if job is None or job.source_fingerprint != fingerprint:
                if job is not None:
                    self._retain_task(job, now)
                job = RepairJob(
                    download_id=record.download_id,
                    title=record.title,
                    source_path=source.host_path,
                    source_fingerprint=fingerprint,
                    discovered_at=now,
                    updated_at=now,
                )
                self.store.state.jobs[record.download_id] = job
            if job.status is not JobStatus.SETTLING:
                continue
            if now - job.discovered_at < self.settle_seconds:
                continue
            try:
                self._start_agent(client, record, job, source, now)
            except PostProcessorError as error:
                self._mark_failure(job, FailureKind.SOURCE_INVALID, str(error), now)
            break

    def iteration(self) -> None:
        now = self.now()
        client = self.client_factory()
        queue = client.queue()
        records = {record.download_id: record for record in queue if record.download_id}
        ready_at_start = {
            job.download_id
            for job in self.store.state.jobs.values()
            if job.status is JobStatus.READY
        }
        staged_at_start = {
            job.download_id
            for job in self.store.state.jobs.values()
            if job.status is JobStatus.STAGED
        }
        self._reconcile_queue(records, now)
        self._advance_existing_jobs(client, now)
        self._promote_ready_jobs(client, queue, ready_at_start, staged_at_start, now)
        self._discover_attempt(client, queue, now)
        self.store.prune_jobs(now)
        self.store.save()

    def write_metrics(self, ok: bool) -> None:
        write_text_atomic(
            self.metrics_file,
            render_lidarr_metrics(self.store.state, ok=ok, now=self.now()),
            mode=0o644,
        )
