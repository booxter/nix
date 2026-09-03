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

from .errors import NeedsAttention, PostProcessorError, SourceInvalid
from .media import safe_component
from .radarr import Radarr
from .radarr_metrics import render_radarr_metrics
from .radarr_models import RadarrManualImportFile, RadarrQueueRecord
from .radarr_probe import VideoVerifier
from .radarr_repair import (
    REPORT_FILE_NAME,
    RESULT_FILE_NAME,
    RadarrQueueStatus,
    RepairOutcome,
    RepairTask,
    load_repair_result,
    render_repair_instruction,
)
from .repair_source import LocatedSource, SourceRoot, locate_source, source_fingerprint
from .radarr_state import (
    ACTIVE_AGENT_STATES,
    FailureKind,
    JobStatus,
    RepairJob,
    RepairStateStore,
    RetainedArtifact,
)

LOG = logging.getLogger("arr-post-processor.radarr")
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
IGNORABLE_SCAN_REJECTIONS = {
    "unable to parse file",
    "unknown movie",
}


class RadarrAgentService:
    def __init__(
        self,
        *,
        client_factory: Callable[[], Radarr],
        hermes: Hermes,
        store: RepairStateStore,
        source_roots: tuple[SourceRoot, ...],
        output_root: Path,
        audit_root: Path,
        metrics_file: Path,
        verifier: VideoVerifier,
        settle_seconds: float,
        agent_timeout_seconds: float,
        command_timeout_seconds: float,
        shadow: bool = False,
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
    def eligible_record(record: RadarrQueueRecord) -> bool:
        return (
            record.status.lower() == "completed"
            and record.tracked_download_status.lower() == "warning"
            and record.protocol.lower() in SUPPORTED_PROTOCOLS
            and record.movie_id > 0
            and bool(record.download_id)
            and record.output_path is not None
        )

    def _expected_task_root(self, download_id: str, attempt_id: UUID) -> Path:
        return self.output_root / safe_component(download_id) / str(attempt_id)

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
        job.candidate = None

    def _expire_artifacts(self, now: float) -> None:
        retained: list[RetainedArtifact] = []
        for artifact in self.store.state.retained_artifacts:
            if artifact.expires_at > now:
                retained.append(artifact)
                continue
            expected = self._expected_task_root(artifact.download_id, artifact.attempt_id)
            if artifact.path.resolve() != expected:
                LOG.error("refusing to remove unsafe Radarr repair artifact: %s", artifact.path)
                retained.append(artifact)
                continue
            if expected.exists():
                shutil.rmtree(expected)
            with contextlib.suppress(OSError):
                expected.parent.rmdir()
        self.store.state.retained_artifacts = retained

    def _mark_failure(self, job: RepairJob, kind: FailureKind, error: str, now: float) -> None:
        if job.status is not JobStatus.NEEDS_ATTENTION:
            self.store.state.totals.increment_failure(kind)
        self._retain_task(job, now)
        job.status = JobStatus.NEEDS_ATTENTION
        job.failure_kind = kind
        job.pending_failure_kind = None
        job.error = error
        job.updated_at = now
        LOG.warning(
            "Radarr repair needs attention: download_id=%s kind=%s error=%s",
            job.download_id,
            kind.value,
            error,
        )

    def _mark_manual_resolved(self, job: RepairJob, now: float) -> None:
        if job.status is not JobStatus.MANUAL_RESOLVED:
            self.store.state.totals.manual += 1
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
        job.candidate = None

    def _complete_import(self, job: RepairJob, now: float) -> None:
        try:
            self._archive_attempt(job)
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
        self.store.state.last_success = now
        started = job.started_at if job.started_at is not None else now
        self.store.state.last_duration = max(0.0, now - started)
        LOG.info("completed Radarr Hermes repair/import: download_id=%s", job.download_id)

    def _process_ready(
        self, client: Radarr, record: RadarrQueueRecord, job: RepairJob, now: float
    ) -> None:
        if job.candidate is None or job.task_root is None or job.task is None:
            self._mark_failure(
                job,
                FailureKind.INVALID_OUTPUT,
                "ready repair has no candidate or task contract",
                now,
            )
            return
        try:
            self.verifier.verify(job.candidate)
            outputs = client.manual_import(job.task_root)
            matches = [
                candidate
                for candidate in outputs
                if candidate.path.resolve() == job.candidate.resolve()
            ]
            if len(matches) != 1:
                raise NeedsAttention(
                    "Radarr did not return exactly one manual-import match for the repair candidate"
                )
            candidate = matches[0]
            if candidate.movie is not None and candidate.movie.id != job.task.movie_id:
                raise NeedsAttention("Radarr matched the repair candidate to a different movie")
            rejections = [item.reason.strip().lower() for item in candidate.rejections]
            if any(reason not in IGNORABLE_SCAN_REJECTIONS for reason in rejections):
                raise NeedsAttention("Radarr rejected the repair candidate by import policy")
            quality = candidate.quality or record.quality
            if not quality:
                raise NeedsAttention("Radarr did not provide a quality for the repair candidate")
            job.status = JobStatus.IMPORTING
            job.command_id = None
            job.import_deadline_at = now + self.command_timeout_seconds
            job.updated_at = now
            self.store.save()
            job.command_id = client.submit_manual_import(
                RadarrManualImportFile(
                    path=job.candidate,
                    movie_id=job.task.movie_id,
                    quality=quality,
                    languages=candidate.languages or [],
                    release_group=candidate.release_group or "",
                    download_id=record.download_id,
                )
            )
            job.updated_at = self.now()
            self.store.save()
            LOG.info(
                "submitted repaired media to Radarr: download_id=%s command_id=%s path=%s",
                record.download_id,
                job.command_id,
                job.candidate,
            )
        except SourceInvalid as error:
            self._mark_failure(job, FailureKind.INVALID_OUTPUT, str(error), now)
        except NeedsAttention as error:
            self._mark_failure(job, FailureKind.IMPORT_REJECTED, str(error), now)
        except PostProcessorError as error:
            self._mark_failure(job, FailureKind.IMPORT_FAILED, str(error), now)
        except Exception as error:
            LOG.exception("unexpected Radarr repaired-media import failure")
            self._mark_failure(job, FailureKind.IMPORT_FAILED, str(error), now)

    def _advance_import(self, client: Radarr, job: RepairJob, now: float) -> None:
        if job.command_id is None:
            self._mark_failure(
                job,
                FailureKind.IMPORT_FAILED,
                "Radarr import submission outcome is ambiguous after restart",
                now,
            )
            return
        try:
            command = client.command(job.command_id)
        except PostProcessorError as error:
            if job.import_deadline_at is not None and now >= job.import_deadline_at:
                self._mark_failure(job, FailureKind.IMPORT_FAILED, str(error), now)
            else:
                job.error = str(error)
                job.updated_at = now
            return
        status = command.status.lower()
        if status in TERMINAL_COMMAND_STATES:
            if status != "completed":
                self._mark_failure(
                    job,
                    FailureKind.IMPORT_FAILED,
                    f"Radarr manual-import command ended as {status}: {command.message}",
                    now,
                )
                return
            job.status = JobStatus.AWAITING_QUEUE_REMOVAL
            job.updated_at = now
            job.error = ""
            LOG.info(
                "Radarr import completed; waiting for queue removal: download_id=%s command_id=%s",
                job.download_id,
                job.command_id,
            )
            return
        if job.import_deadline_at is not None and now >= job.import_deadline_at:
            self._mark_failure(
                job,
                FailureKind.IMPORT_FAILED,
                f"Radarr manual-import command {job.command_id} timed out",
                now,
            )

    def _new_settling_job(
        self, record: RadarrQueueRecord, fingerprint: str, now: float
    ) -> RepairJob:
        return RepairJob(
            download_id=record.download_id,
            title=record.title,
            source_fingerprint=fingerprint,
            discovered_at=now,
            updated_at=now,
        )

    def _reset_for_source(
        self, record: RadarrQueueRecord, fingerprint: str, now: float
    ) -> RepairJob:
        previous = self.store.state.jobs.get(record.download_id)
        if previous is not None:
            self._retain_task(previous, now)
        job = self._new_settling_job(record, fingerprint, now)
        self.store.state.jobs[record.download_id] = job
        LOG.info(
            "settling unprocessed Radarr media: download_id=%s source=%s",
            record.download_id,
            record.output_path or "",
        )
        return job

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
                self._mark_failure(
                    job,
                    kind or FailureKind.AGENT_START_AMBIGUOUS,
                    error,
                    now,
                )
            return
        job.status = JobStatus.AGENT_STOPPING
        try:
            self.hermes.stop_run(job.run_id)
        except HermesError as stop_error:
            LOG.warning("could not stop Hermes run %s: %s", job.run_id, stop_error)

    def _consume_result(self, job: RepairJob, now: float) -> None:
        if job.task is None or job.task_root is None:
            self._mark_failure(
                job,
                FailureKind.INVALID_OUTPUT,
                "Hermes attempt has no persisted task contract",
                now,
            )
            return
        try:
            validated = load_repair_result(job.task_root, job.task)
        except NeedsAttention as error:
            self._mark_failure(job, FailureKind.INVALID_OUTPUT, str(error), now)
            return
        if validated.result.outcome is RepairOutcome.UNRESOLVED:
            self._mark_failure(
                job,
                FailureKind.AGENT_UNRESOLVED,
                validated.result.reason,
                now,
            )
            return
        assert validated.candidate is not None
        job.status = JobStatus.READY
        job.candidate = validated.candidate
        job.resolution = validated.result.reason
        job.updated_at = now
        job.error = ""
        job.failure_kind = None
        LOG.info(
            "Hermes produced a Radarr repair candidate: download_id=%s path=%s",
            job.download_id,
            validated.candidate,
        )

    def _advance_ambiguous_start(self, job: RepairJob, now: float) -> bool:
        if job.status is not JobStatus.AGENT_STARTING or job.run_id is not None:
            return False
        if job.task_root is not None and (job.task_root / RESULT_FILE_NAME).exists():
            self._consume_result(job, now)
        elif job.agent_deadline_at is not None and now >= job.agent_deadline_at:
            self._mark_failure(
                job,
                FailureKind.AGENT_START_AMBIGUOUS,
                "Hermes run start outcome was ambiguous and no result appeared",
                now,
            )
        return True

    def _resolve_requested_stop(self, job: RepairJob, now: float) -> bool:
        if job.dismiss_requested:
            self._mark_manual_resolved(job, now)
            return True
        if job.pending_failure_kind is not None:
            self._mark_failure(job, job.pending_failure_kind, job.error, now)
            return True
        return False

    def _handle_missing_run(self, job: RepairJob, now: float) -> None:
        if self._resolve_requested_stop(job, now):
            return
        if job.task_root is not None and (job.task_root / RESULT_FILE_NAME).exists():
            self._consume_result(job, now)
            return
        self._mark_failure(
            job,
            FailureKind.AGENT_LOST,
            "Hermes no longer knows the run and no result manifest exists",
            now,
        )

    def _handle_run_error(self, job: RepairJob, error: HermesError, now: float) -> None:
        job.error = str(error)
        job.updated_at = now
        if job.stop_deadline_at is None or now < job.stop_deadline_at:
            return
        if job.dismiss_requested:
            self._mark_manual_resolved(job, now)
            return
        self._mark_failure(
            job,
            job.pending_failure_kind or FailureKind.AGENT_LOST,
            str(error),
            now,
        )

    def _handle_active_run(self, job: RepairJob, status: RunStatus, now: float) -> bool:
        if status.state not in {RunState.QUEUED, RunState.RUNNING, RunState.STOPPING}:
            return False
        if (
            job.status is JobStatus.AGENT_STOPPING
            and job.stop_deadline_at is not None
            and now >= job.stop_deadline_at
        ):
            if job.dismiss_requested:
                self._mark_manual_resolved(job, now)
            else:
                self._mark_failure(
                    job,
                    job.pending_failure_kind or FailureKind.AGENT_LOST,
                    job.error or "Hermes did not stop the repair run",
                    now,
                )
        return True

    def _finish_agent_run(self, job: RepairJob, status: RunStatus, now: float) -> None:
        if status.state is RunState.COMPLETED:
            self._consume_result(job, now)
        elif status.state is RunState.FAILED:
            self._mark_failure(
                job,
                FailureKind.AGENT_FAILED,
                status.error or "Hermes repair run failed",
                now,
            )
        else:
            self._mark_failure(
                job,
                FailureKind.AGENT_CANCELLED,
                "Hermes repair run was cancelled",
                now,
            )

    def _advance_agent(self, job: RepairJob, now: float) -> None:
        if self._advance_ambiguous_start(job, now):
            return
        if job.run_id is None:
            self._mark_failure(
                job,
                FailureKind.AGENT_LOST,
                "active Hermes attempt has no run ID",
                now,
            )
            return
        if (
            job.status is JobStatus.AGENT_RUNNING
            and job.agent_deadline_at is not None
            and now >= job.agent_deadline_at
        ):
            self._request_stop(
                job,
                kind=FailureKind.AGENT_TIMED_OUT,
                error="Hermes repair run timed out",
                now=now,
            )

        try:
            status = self.hermes.get_run(job.run_id)
        except HermesHttpError as error:
            if error.status == 404:
                self._handle_missing_run(job, now)
            else:
                job.error = str(error)
                job.updated_at = now
            return
        except HermesError as error:
            self._handle_run_error(job, error, now)
            return

        if self._handle_active_run(job, status, now):
            return
        if status.state is RunState.WAITING_FOR_APPROVAL:
            self._request_stop(
                job,
                kind=FailureKind.APPROVAL_REQUIRED,
                error="Hermes requested approval despite autonomous configuration",
                now=now,
            )
            return
        if self._resolve_requested_stop(job, now):
            return
        self._finish_agent_run(job, status, now)

    def _start_agent(
        self,
        client: Radarr,
        record: RadarrQueueRecord,
        job: RepairJob,
        source: LocatedSource,
        now: float,
    ) -> None:
        movie = client.movie(record.movie_id)
        attempt_id = self.uuid_factory()
        component = safe_component(record.download_id)
        task_root = self._expected_task_root(record.download_id, attempt_id)
        task_root.parent.mkdir(parents=True, exist_ok=True, mode=0o770)
        task_root.mkdir(mode=0o770)
        task = RepairTask(
            attempt_id=attempt_id,
            download_id=record.download_id,
            source_fingerprint=job.source_fingerprint,
            movie_id=movie.id,
            movie_title=movie.title,
            movie_year=movie.year,
            movie_runtime_minutes=movie.runtime,
            queue_title=record.title,
            radarr_queue_status=RadarrQueueStatus(
                status=record.status,
                tracked_download_status=record.tracked_download_status,
                tracked_download_state=record.tracked_download_state,
                messages=record.status_messages,
            ),
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
            job.updated_at = now
            return
        job.status = JobStatus.AGENT_RUNNING
        job.updated_at = now
        LOG.info(
            "started Hermes Radarr repair: download_id=%s run_id=%s attempt_id=%s",
            record.download_id,
            job.run_id,
            attempt_id,
        )

    def _observe_active_source(self, record: RadarrQueueRecord, job: RepairJob, now: float) -> None:
        assert record.output_path is not None
        try:
            fingerprint = source_fingerprint(locate_source(record.output_path, self.source_roots))
        except PostProcessorError as error:
            self._request_stop(
                job,
                kind=FailureKind.SOURCE_CHANGED,
                error=str(error),
                now=now,
            )
            return
        if fingerprint != job.source_fingerprint:
            self._request_stop(
                job,
                kind=FailureKind.SOURCE_CHANGED,
                error="Radarr source changed while Hermes was processing it",
                now=now,
            )

    def _reconcile_queue(self, records: dict[str, RadarrQueueRecord], now: float) -> None:
        for job in self.store.state.jobs.values():
            record = records.get(job.download_id)
            if record is not None and self.eligible_record(record):
                job.missing_queue_observations = 0
                if job.status in {JobStatus.AGENT_STARTING, JobStatus.AGENT_RUNNING}:
                    self._observe_active_source(record, job, now)
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
                    error="Radarr queue item disappeared while Hermes was processing it",
                    now=now,
                    dismiss=True,
                )
            elif job.status is JobStatus.IMPORTING:
                continue
            elif job.status is JobStatus.AWAITING_QUEUE_REMOVAL:
                self._complete_import(job, now)
            else:
                self._mark_manual_resolved(job, now)

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
        self._reconcile_queue(records, now)
        for active_job in self.store.state.jobs.values():
            if active_job.status in ACTIVE_AGENT_STATES:
                self._advance_agent(active_job, now)
            elif active_job.status is JobStatus.IMPORTING:
                self._advance_import(client, active_job, now)

        for record in queue:
            ready_job = self.store.state.jobs.get(record.download_id)
            if (
                self.eligible_record(record)
                and record.download_id in ready_at_start
                and ready_job is not None
                and ready_job.status is JobStatus.READY
                and not self.shadow
            ):
                self._process_ready(client, record, ready_job, now)
                break

        if not any(job.status in ACTIVE_AGENT_STATES for job in self.store.state.jobs.values()):
            for record in queue:
                if not self.eligible_record(record):
                    continue
                assert record.output_path is not None
                try:
                    source = locate_source(record.output_path, self.source_roots)
                    fingerprint = source_fingerprint(source)
                except PostProcessorError as error:
                    observed_job = self.store.state.jobs.get(record.download_id)
                    if observed_job is None:
                        observed_job = self._new_settling_job(record, "", now)
                        self.store.state.jobs[record.download_id] = observed_job
                    self._mark_failure(observed_job, FailureKind.SOURCE_INVALID, str(error), now)
                    continue
                observed_job = self.store.state.jobs.get(record.download_id)
                if observed_job is None or observed_job.source_fingerprint != fingerprint:
                    observed_job = self._reset_for_source(record, fingerprint, now)
                if observed_job.status is not JobStatus.SETTLING:
                    continue
                if now - observed_job.discovered_at < self.settle_seconds:
                    continue
                self._start_agent(client, record, observed_job, source, now)
                break

        self._expire_artifacts(now)
        self.store.prune_jobs(now)
        self.store.save()

    def write_metrics(self, ok: bool) -> None:
        write_text_atomic(
            self.metrics_file,
            render_radarr_metrics(self.store.state, ok=ok, now=self.now()),
            mode=0o644,
        )
