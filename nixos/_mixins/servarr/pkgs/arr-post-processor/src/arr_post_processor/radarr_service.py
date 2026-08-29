from __future__ import annotations

import logging
import shutil
import time
from pathlib import Path
from typing import Callable

from atomic_file_writes import write_text_atomic

from .errors import CueSplitterError, NeedsAttention
from .media_join import (
    JoinBackend,
    build_join_plan,
    build_single_file_plan,
    download_fingerprint,
    prepare_joined_media,
)
from .metrics import render_metrics
from .radarr import Radarr
from .radarr_models import RadarrManualImportFile, RadarrQueueRecord
from .state import PROCESSING_JOB_STATES, Job, StateStore


LOG = logging.getLogger("arr-post-processor.radarr-media-join")
METRICS_PREFIX = "host_observability_radarr_multipart_joiner"
SUPPORTED_PROTOCOLS = {
    "torrent",
    "torrentdownloadprotocol",
    "usenet",
    "usenetdownloadprotocol",
}
TERMINAL_COMMAND_STATES = {"completed", "failed", "aborted", "cancelled", "orphaned"}
MISSING_QUEUE_CONFIRMATIONS = 3
UNABLE_TO_PARSE_FILE = "unable to parse file"


class RadarrJoinService:
    def __init__(
        self,
        *,
        client_factory: Callable[[], Radarr],
        backend: JoinBackend,
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
        self.backend = backend
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
    def eligible_record(record: RadarrQueueRecord) -> bool:
        return (
            record.status.lower() == "completed"
            and record.tracked_download_status.lower() == "warning"
            and record.tracked_download_state.lower() == "importblocked"
            and record.protocol.lower() in SUPPORTED_PROTOCOLS
            and record.movie_id > 0
            and bool(record.download_id)
            and record.output_path is not None
        )

    def mark_attention(self, job: Job, error: str, now: float) -> None:
        if job.status != "awaiting_manual_match":
            self.store.state.totals.manual += 1
        job.status = "awaiting_manual_match"
        job.error = error
        job.updated_at = now
        LOG.warning(
            "multipart job needs attention: download_id=%s error=%s", job.download_id, error
        )

    def wait_for_import(self, client: Radarr, command_id: int) -> None:
        deadline = time.monotonic() + self.command_timeout_seconds
        while time.monotonic() < deadline:
            command = client.command(command_id)
            status = command.status.lower()
            if status in TERMINAL_COMMAND_STATES:
                if status != "completed":
                    raise NeedsAttention(
                        f"Radarr manual-import command {command_id} ended as {status}: "
                        f"{command.message}"
                    )
                return
            self.sleep(2.0)
        raise NeedsAttention(f"Radarr manual-import command {command_id} timed out")

    @staticmethod
    def has_only_filename_parse_failures(record: RadarrQueueRecord) -> bool:
        reasons = [
            reason.strip().lower()
            for status in record.status_messages
            for reason in status.messages
            if reason.strip()
        ]
        return bool(reasons) and all(reason == UNABLE_TO_PARSE_FILE for reason in reasons)

    def import_single_file(
        self,
        client: Radarr,
        record: RadarrQueueRecord,
        job: Job,
        movie_id: int,
        path: Path,
        now: float,
    ) -> None:
        if record.output_path is None:
            raise CueSplitterError("Radarr queue record does not contain an output path")
        candidates = [
            candidate
            for candidate in client.manual_import(record.output_path, record)
            if candidate.path.resolve() == path.resolve()
        ]
        if len(candidates) != 1 or candidates[0].movie.id != movie_id:
            raise NeedsAttention("Radarr did not uniquely match the single file to its queue item")
        candidate = candidates[0]
        rejections = [rejection.reason.strip().lower() for rejection in candidate.rejections]
        if not rejections or any(reason != UNABLE_TO_PARSE_FILE for reason in rejections):
            raise NeedsAttention(
                "Radarr manual-import candidate has rejections other than filename parsing"
            )
        quality = candidate.quality or record.quality
        if not quality:
            raise NeedsAttention("Radarr did not provide a quality for the single file")
        job.status = "importing"
        job.started_at = now
        job.updated_at = self.now()
        job.resolution = "single_file_import"
        self.store.save()
        command_id = client.submit_manual_import(
            RadarrManualImportFile(
                path=path,
                movie_id=movie_id,
                quality=quality,
                languages=candidate.languages or [],
                release_group=candidate.release_group or "",
                download_id=record.download_id,
            )
        )
        job.command_id = command_id
        self.wait_for_import(client, command_id)
        job.status = "awaiting_queue_removal"
        job.updated_at = self.now()
        job.error = ""

    def observe(self, record: RadarrQueueRecord, job: Job, now: float) -> bool:
        if record.output_path is None:
            raise CueSplitterError("Radarr queue record does not contain an output path")
        current_fingerprint = download_fingerprint(record.output_path)
        if current_fingerprint != job.fingerprint:
            job.fingerprint = current_fingerprint
            job.status = "settling"
            job.discovered_at = now
            job.updated_at = now
            return False
        discovered_at = job.discovered_at if job.discovered_at is not None else now
        return now - discovered_at >= self.settle_seconds

    def process(self, client: Radarr, record: RadarrQueueRecord, job: Job, now: float) -> None:
        movie = client.movie(record.movie_id)
        if self.has_only_filename_parse_failures(record):
            single_file = build_single_file_plan(record, movie, self.allowed_roots, self.backend)
            if single_file is not None:
                self.import_single_file(
                    client,
                    record,
                    job,
                    movie.id,
                    single_file.path,
                    now,
                )
                return
        plan = build_join_plan(record, movie, self.allowed_roots, self.backend)
        if plan is None:
            if job.status != "ignored":
                self.store.state.totals.ignored += 1
            job.status = "ignored"
            job.updated_at = now
            job.error = (
                "download is not an unambiguous runtime-matched single-file or multipart movie"
            )
            job.resolution = "unsupported"
            return
        if not record.quality:
            raise NeedsAttention("Radarr queue record does not contain a quality")
        job.status = "joining"
        job.started_at = now
        job.updated_at = now
        job.tracks = len(plan.parts)
        job.resolution = "multipart_join"
        self.store.save()
        output = prepare_joined_media(record, movie, plan, self.work_root, self.backend)
        job.ready_root = output.parent
        job.status = "importing"
        job.updated_at = self.now()
        self.store.save()
        command_id = client.submit_manual_import(
            RadarrManualImportFile(
                path=output,
                movie_id=movie.id,
                quality=record.quality,
                download_id=record.download_id,
            )
        )
        job.command_id = command_id
        self.wait_for_import(client, command_id)
        job.status = "awaiting_queue_removal"
        job.updated_at = self.now()
        job.error = ""

    def reconcile(self, queued_download_ids: set[str], now: float) -> None:
        for job in self.store.state.jobs.values():
            if job.download_id in queued_download_ids:
                job.missing_queue_observations = 0
                continue
            if job.status not in {"awaiting_queue_removal", "awaiting_manual_match"}:
                continue
            job.missing_queue_observations += 1
            if job.missing_queue_observations < self.missing_queue_confirmations:
                continue
            if job.status == "awaiting_queue_removal":
                if job.ready_root is None and job.resolution != "single_file_import":
                    self.mark_attention(job, "completed import has no staging path", now)
                    continue
                if job.ready_root is not None:
                    if not job.ready_root.is_relative_to(self.work_root):
                        self.mark_attention(job, "refusing to clean an unsafe staging path", now)
                        continue
                    if job.ready_root.exists():
                        shutil.rmtree(job.ready_root)
                job.status = "complete"
                job.updated_at = now
                self.store.state.totals.success += 1
                self.store.state.totals.tracks += job.tracks
                self.store.state.last_success = now
                started = job.started_at if job.started_at is not None else now
                self.store.state.last_duration = max(0.0, now - started)
            else:
                job.status = "manual_resolved"
                job.updated_at = now

    def recover_interrupted(self, now: float) -> None:
        for job in self.store.state.jobs.values():
            if job.status in PROCESSING_JOB_STATES | {"joining"}:
                self.mark_attention(
                    job, "service restarted while multipart media was processing", now
                )

    def iteration(self) -> None:
        now = self.now()
        client = self.client_factory()
        records = client.queue()
        queued_ids = {record.download_id for record in records if record.download_id}
        self.recover_interrupted(now)
        self.reconcile(queued_ids, now)
        ready: list[tuple[RadarrQueueRecord, Job]] = []
        for record in records:
            if not self.eligible_record(record):
                continue
            job = self.store.job(record.download_id, title=record.title)
            if job.status in {
                "awaiting_manual_match",
                "awaiting_queue_removal",
                "complete",
                "manual_resolved",
            }:
                continue
            if job.status == "ignored" and job.resolution == "unsupported":
                continue
            try:
                if self.observe(record, job, now):
                    ready.append((record, job))
            except Exception as error:
                LOG.exception(
                    "multipart job observation failed: download_id=%s", record.download_id
                )
                self.mark_attention(job, str(error), now)
        if not any(
            job.status in PROCESSING_JOB_STATES | {"joining"}
            for job in self.store.state.jobs.values()
        ):
            for record, job in ready:
                try:
                    self.process(client, record, job, now)
                except Exception as error:
                    LOG.exception("multipart job failed: download_id=%s", record.download_id)
                    self.mark_attention(job, str(error), now)
                break
        self.store.prune(now)
        self.store.save()

    def write_metrics(self, ok: bool) -> None:
        write_text_atomic(
            self.metrics_file,
            render_metrics(
                self.store.state,
                ok=ok,
                now=self.now(),
                prefix=METRICS_PREFIX,
            ),
            mode=0o644,
        )
