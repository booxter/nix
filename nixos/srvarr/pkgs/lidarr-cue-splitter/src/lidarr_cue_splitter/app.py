from __future__ import annotations

import argparse
import logging
import os
import shutil
import sys
import time
from pathlib import Path
from typing import Callable

from .config import read_api_key
from .errors import CueSplitterError, ManualMatchRequired, NeedsAttention, SourceInvalid
from .files import atomic_write
from .lidarr import Lidarr, LidarrClient
from .media import (
    STAGING_DIR_NAME,
    UnflacRunner,
    build_manual_import_files,
    cue_already_split_audio_files,
    inspection_summary,
    is_within,
    output_fingerprint,
    safe_component,
    source_fingerprint,
)
from .metrics import render_metrics
from .models import CueSummary, QueueRecord
from .state import (
    PROCESSING_JOB_STATES,
    PROBLEM_JOB_STATES,
    Job,
    StateStore,
)


LOG = logging.getLogger("lidarr-cue-splitter")
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
        atomic_write(
            self.metrics_file,
            render_metrics(self.store.state, ok=ok, now=self.now()),
        )


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
