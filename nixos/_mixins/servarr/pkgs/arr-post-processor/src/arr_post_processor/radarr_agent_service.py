from __future__ import annotations

import logging
import shutil
import time
from collections.abc import Callable
from pathlib import Path, PurePosixPath
from uuid import UUID, uuid4

from hermes_runs.client import Client as Hermes, HermesError, HermesHttpError, RunState

from .errors import NeedsAttention, PostProcessorError
from .media import safe_component
from .radarr import Radarr
from .radarr_models import RadarrQueueRecord
from .radarr_repair import (
    RESULT_FILE_NAME,
    RepairOutcome,
    RepairTask,
    load_repair_result,
    render_repair_instruction,
)
from .radarr_source import LocatedSource, SourceRoot, locate_source, source_fingerprint
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


class RadarrAgentService:
    def __init__(
        self,
        *,
        client_factory: Callable[[], Radarr],
        hermes: Hermes,
        store: RepairStateStore,
        source_roots: tuple[SourceRoot, ...],
        output_root: Path,
        settle_seconds: float,
        agent_timeout_seconds: float,
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
        self.settle_seconds = settle_seconds
        self.agent_timeout_seconds = agent_timeout_seconds
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
            try:
                expected.parent.rmdir()
            except OSError:
                pass
        self.store.state.retained_artifacts = retained

    def _mark_failure(self, job: RepairJob, kind: FailureKind, error: str, now: float) -> None:
        if job.status is not JobStatus.NEEDS_ATTENTION:
            self.store.state.totals.increment_failure(kind)
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

    def _advance_agent(self, job: RepairJob, now: float) -> None:
        if job.status is JobStatus.AGENT_STARTING and job.run_id is None:
            if job.task_root is not None and (job.task_root / RESULT_FILE_NAME).exists():
                self._consume_result(job, now)
            elif job.agent_deadline_at is not None and now >= job.agent_deadline_at:
                self._mark_failure(
                    job,
                    FailureKind.AGENT_START_AMBIGUOUS,
                    "Hermes run start outcome was ambiguous and no result appeared",
                    now,
                )
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
            if error.status != 404:
                job.error = str(error)
                job.updated_at = now
                return
            if job.dismiss_requested:
                self._mark_manual_resolved(job, now)
            elif job.pending_failure_kind is not None:
                self._mark_failure(job, job.pending_failure_kind, job.error, now)
            elif job.task_root is not None and (job.task_root / RESULT_FILE_NAME).exists():
                self._consume_result(job, now)
            else:
                self._mark_failure(
                    job,
                    FailureKind.AGENT_LOST,
                    "Hermes no longer knows the run and no result manifest exists",
                    now,
                )
            return
        except HermesError as error:
            job.error = str(error)
            job.updated_at = now
            if job.stop_deadline_at is not None and now >= job.stop_deadline_at:
                if job.dismiss_requested:
                    self._mark_manual_resolved(job, now)
                else:
                    self._mark_failure(
                        job,
                        job.pending_failure_kind or FailureKind.AGENT_LOST,
                        str(error),
                        now,
                    )
            return

        if status.state in {RunState.QUEUED, RunState.RUNNING, RunState.STOPPING}:
            return
        if status.state is RunState.WAITING_FOR_APPROVAL:
            self._request_stop(
                job,
                kind=FailureKind.APPROVAL_REQUIRED,
                error="Hermes requested approval despite autonomous configuration",
                now=now,
            )
            return
        if job.dismiss_requested:
            self._mark_manual_resolved(job, now)
            return
        if job.pending_failure_kind is not None:
            self._mark_failure(job, job.pending_failure_kind, job.error, now)
            return
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
            else:
                self._mark_manual_resolved(job, now)

    def iteration(self) -> None:
        now = self.now()
        client = self.client_factory()
        queue = client.queue()
        records = {record.download_id: record for record in queue if record.download_id}
        self._reconcile_queue(records, now)
        for active_job in self.store.state.jobs.values():
            if active_job.status in ACTIVE_AGENT_STATES:
                self._advance_agent(active_job, now)

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
