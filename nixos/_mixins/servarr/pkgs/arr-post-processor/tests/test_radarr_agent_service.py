from __future__ import annotations

import json
from collections.abc import Iterator
from pathlib import Path
from uuid import UUID

from hermes_runs.client import (
    HermesError,
    HermesHttpError,
    JsonObject,
    RunState,
    RunStatus,
    RunSummary,
    StopResult,
)

from arr_post_processor.radarr_agent_service import RadarrAgentService
from arr_post_processor.radarr_models import RadarrMovie, RadarrQueueRecord
from arr_post_processor.radarr_source import SourceRoot
from arr_post_processor.radarr_state import FailureKind, JobStatus, RepairStateStore


ATTEMPT_ID = UUID("12345678-1234-5678-1234-567812345678")


class Clock:
    def __init__(self, value: float = 1000.0) -> None:
        self.value = value

    def __call__(self) -> float:
        return self.value


class FakeRadarr:
    def __init__(self, records: list[RadarrQueueRecord]) -> None:
        self.records = records
        self.movie_value = RadarrMovie(id=42, title="Test Movie", year=2020, runtime=120)

    def queue(self) -> list[RadarrQueueRecord]:
        return self.records

    def movie(self, movie_id: int) -> RadarrMovie:
        assert movie_id == self.movie_value.id
        return self.movie_value


class FakeHermes:
    def __init__(self) -> None:
        self.instructions: list[str] = []
        self.run_id = "run_123"
        self.state = RunState.RUNNING
        self.error = ""
        self.start_error: HermesError | None = None
        self.get_error: HermesError | None = None
        self.stopped: list[str] = []

    def start_run(self, instruction: str) -> str:
        self.instructions.append(instruction)
        if self.start_error is not None:
            raise self.start_error
        return self.run_id

    def get_run(self, run_id: str) -> RunStatus:
        assert run_id == self.run_id
        if self.get_error is not None:
            raise self.get_error
        raw: JsonObject = {
            "run_id": run_id,
            "status": self.state.value,
            "error": self.error,
        }
        return RunStatus(
            run_id=run_id,
            state=self.state,
            created_at=1000.0,
            updated_at=1001.0,
            model="radarr-repair",
            last_event="",
            output="",
            error=self.error,
            usage={},
            raw=raw,
        )

    def stop_run(self, run_id: str) -> StopResult:
        self.stopped.append(run_id)
        raw: JsonObject = {"run_id": run_id, "status": "stopping"}
        return StopResult(run_id=run_id, state=RunState.STOPPING, raw=raw)

    def list_runs(self, limit: int) -> list[RunSummary]:
        return []

    def watch_run(self, run_id: str) -> Iterator[JsonObject]:
        yield from ()

    def approve_run(self, run_id: str, choice: str, resolve_all: bool) -> JsonObject:
        raise AssertionError("the autonomous processor must not approve Hermes commands")


def queue_record(path: Path, **changes: object) -> RadarrQueueRecord:
    values: dict[str, object] = {
        "id": 1,
        "download_id": "download-id",
        "output_path": path,
        "title": "Test.Movie.2020.1080p",
        "status": "completed",
        "protocol": "torrent",
        "movie_id": 42,
        "tracked_download_status": "warning",
        "tracked_download_state": "importBlocked",
        "status_messages": [{"messages": ["anything Radarr considers blocked"]}],
        "quality": {"quality": {"id": 7, "name": "Bluray-1080p"}},
    }
    values.update(changes)
    return RadarrQueueRecord.model_validate(values)


def service_fixture(
    tmp_path: Path,
) -> tuple[RadarrAgentService, FakeRadarr, FakeHermes, RepairStateStore, Clock, Path, Path]:
    source_root = tmp_path / "torrents"
    source_root.mkdir()
    source = source_root / "Test.Movie.2020.1080p"
    source.mkdir()
    (source / "part1.mkv").write_bytes(b"part one")
    output_root = tmp_path / "processed"
    output_root.mkdir()
    radarr = FakeRadarr([queue_record(source)])
    hermes = FakeHermes()
    store = RepairStateStore(tmp_path / "state.json")
    clock = Clock()
    attempt_ids = iter(
        [
            ATTEMPT_ID,
            UUID("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"),
        ]
    )
    service = RadarrAgentService(
        client_factory=lambda: radarr,
        hermes=hermes,
        store=store,
        source_roots=(SourceRoot(name="torrents", host_path=source_root),),
        output_root=output_root,
        settle_seconds=60,
        agent_timeout_seconds=3600,
        now=clock,
        uuid_factory=lambda: next(attempt_ids),
    )
    return service, radarr, hermes, store, clock, source, output_root


def start_attempt(service: RadarrAgentService, store: RepairStateStore, clock: Clock) -> Path:
    service.iteration()
    assert store.state.jobs["download-id"].status is JobStatus.SETTLING
    clock.value += 60
    service.iteration()
    job = store.state.jobs["download-id"]
    assert job.status is JobStatus.AGENT_RUNNING
    assert job.task_root is not None
    return job.task_root


def write_result(
    store: RepairStateStore,
    *,
    outcome: str = "repaired",
    candidate: str | None = "Test Movie (2020).mkv",
) -> None:
    job = store.state.jobs["download-id"]
    assert job.task is not None
    assert job.task_root is not None
    if candidate is not None:
        path = job.task_root / candidate
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"repaired media")
        path.chmod(0o660)
    payload = {
        "schema_version": 1,
        "attempt_id": str(job.task.attempt_id),
        "download_id": job.task.download_id,
        "source_fingerprint": job.task.source_fingerprint,
        "outcome": outcome,
        "candidate": candidate,
        "reason": "repair result",
    }
    (job.task_root / "result.json").write_text(json.dumps(payload))


def test_eligibility_uses_radarr_warning_not_repair_heuristics(tmp_path: Path) -> None:
    record = queue_record(
        tmp_path,
        tracked_download_state="unexpectedFutureState",
        status_messages=[{"messages": ["a completely new Radarr failure"]}],
    )

    assert RadarrAgentService.eligible_record(record)
    assert not RadarrAgentService.eligible_record(
        record.model_copy(update={"tracked_download_status": "ok"})
    )


def test_settled_source_starts_one_persisted_agent_attempt(tmp_path: Path) -> None:
    service, _radarr, hermes, store, clock, _source, output_root = service_fixture(tmp_path)

    task_root = start_attempt(service, store, clock)

    job = store.state.jobs["download-id"]
    assert task_root == output_root / "download-id-1700aa17a44c" / str(ATTEMPT_ID)
    assert job.run_id == "run_123"
    assert job.task is not None
    assert job.task.source_path == "input/torrents/Test.Movie.2020.1080p"
    assert job.task.output_path.endswith(str(ATTEMPT_ID))
    assert len(job.source_fingerprint) == 64
    assert len(hermes.instructions) == 1

    reloaded = RepairStateStore(tmp_path / "state.json")
    assert reloaded.state.jobs["download-id"].run_id == "run_123"


def test_completed_run_accepts_only_correlated_manifest(tmp_path: Path) -> None:
    service, _radarr, hermes, store, clock, _source, _output = service_fixture(tmp_path)
    start_attempt(service, store, clock)
    write_result(store)
    hermes.state = RunState.COMPLETED

    service.iteration()

    job = store.state.jobs["download-id"]
    assert job.status is JobStatus.READY
    assert job.candidate is not None
    assert job.candidate.name == "Test Movie (2020).mkv"


def test_unresolved_run_is_terminal_for_unchanged_source(tmp_path: Path) -> None:
    service, _radarr, hermes, store, clock, _source, _output = service_fixture(tmp_path)
    start_attempt(service, store, clock)
    write_result(store, outcome="unresolved", candidate=None)
    hermes.state = RunState.COMPLETED

    service.iteration()
    service.iteration()

    job = store.state.jobs["download-id"]
    assert job.status is JobStatus.NEEDS_ATTENTION
    assert job.failure_kind is FailureKind.AGENT_UNRESOLVED
    assert store.state.totals.agent_unresolved == 1
    assert len(hermes.instructions) == 1


def test_approval_request_is_stopped_and_never_approved(tmp_path: Path) -> None:
    service, _radarr, hermes, store, clock, _source, _output = service_fixture(tmp_path)
    start_attempt(service, store, clock)
    hermes.state = RunState.WAITING_FOR_APPROVAL

    service.iteration()

    assert store.state.jobs["download-id"].status is JobStatus.AGENT_STOPPING
    assert hermes.stopped == ["run_123"]
    hermes.state = RunState.CANCELLED
    service.iteration()
    job = store.state.jobs["download-id"]
    assert job.status is JobStatus.NEEDS_ATTENTION
    assert job.failure_kind is FailureKind.APPROVAL_REQUIRED


def test_missing_api_status_recovers_a_durable_manifest(tmp_path: Path) -> None:
    service, _radarr, hermes, store, clock, _source, _output = service_fixture(tmp_path)
    start_attempt(service, store, clock)
    write_result(store)
    hermes.get_error = HermesHttpError(404, "run not found")

    service.iteration()

    assert store.state.jobs["download-id"].status is JobStatus.READY


def test_failed_run_is_terminal_for_unchanged_source(tmp_path: Path) -> None:
    service, _radarr, hermes, store, clock, _source, _output = service_fixture(tmp_path)
    start_attempt(service, store, clock)
    hermes.state = RunState.FAILED
    hermes.error = "model provider failed"

    service.iteration()
    service.iteration()

    job = store.state.jobs["download-id"]
    assert job.status is JobStatus.NEEDS_ATTENTION
    assert job.failure_kind is FailureKind.AGENT_FAILED
    assert job.error == "model provider failed"
    assert len(hermes.instructions) == 1


def test_timed_out_run_is_stopped_and_not_consumed(tmp_path: Path) -> None:
    service, _radarr, hermes, store, clock, _source, _output = service_fixture(tmp_path)
    start_attempt(service, store, clock)
    clock.value += 3600

    service.iteration()

    assert store.state.jobs["download-id"].status is JobStatus.AGENT_STOPPING
    assert hermes.stopped == ["run_123"]
    hermes.state = RunState.CANCELLED
    service.iteration()
    job = store.state.jobs["download-id"]
    assert job.status is JobStatus.NEEDS_ATTENTION
    assert job.failure_kind is FailureKind.AGENT_TIMED_OUT


def test_source_change_stops_the_active_attempt(tmp_path: Path) -> None:
    service, _radarr, hermes, store, clock, source, _output = service_fixture(tmp_path)
    start_attempt(service, store, clock)
    (source / "part2.mkv").write_bytes(b"new source data")

    service.iteration()

    job = store.state.jobs["download-id"]
    assert job.status is JobStatus.AGENT_STOPPING
    assert job.pending_failure_kind is FailureKind.SOURCE_CHANGED
    assert hermes.stopped == ["run_123"]


def test_ambiguous_start_recovers_manifest_after_restart(tmp_path: Path) -> None:
    service, radarr, hermes, store, clock, _source, output_root = service_fixture(tmp_path)
    hermes.start_error = HermesError("connection closed")
    service.iteration()
    clock.value += 60
    service.iteration()
    assert store.state.jobs["download-id"].status is JobStatus.AGENT_STARTING
    write_result(store)

    reloaded = RepairStateStore(tmp_path / "state.json")
    restarted = RadarrAgentService(
        client_factory=lambda: radarr,
        hermes=FakeHermes(),
        store=reloaded,
        source_roots=(SourceRoot(name="torrents", host_path=tmp_path / "torrents"),),
        output_root=output_root,
        settle_seconds=60,
        agent_timeout_seconds=3600,
        now=clock,
    )

    restarted.iteration()

    assert reloaded.state.jobs["download-id"].status is JobStatus.READY


def test_new_source_fingerprint_gets_one_new_attempt(tmp_path: Path) -> None:
    service, _radarr, hermes, store, clock, source, _output = service_fixture(tmp_path)
    old_task = start_attempt(service, store, clock)
    write_result(store, outcome="unresolved", candidate=None)
    hermes.state = RunState.COMPLETED
    service.iteration()
    assert store.state.jobs["download-id"].status is JobStatus.NEEDS_ATTENTION

    (source / "part2.mkv").write_bytes(b"part two")
    service.iteration()
    assert store.state.jobs["download-id"].status is JobStatus.SETTLING
    clock.value += 60
    hermes.state = RunState.RUNNING
    service.iteration()

    assert store.state.jobs["download-id"].status is JobStatus.AGENT_RUNNING
    assert len(hermes.instructions) == 2
    assert store.state.retained_artifacts[0].path == old_task


def test_disappearing_queue_stops_active_run_and_dismisses_it(tmp_path: Path) -> None:
    service, radarr, hermes, store, clock, _source, _output = service_fixture(tmp_path)
    start_attempt(service, store, clock)
    radarr.records = []

    service.iteration()
    service.iteration()
    service.iteration()

    assert store.state.jobs["download-id"].status is JobStatus.AGENT_STOPPING
    assert hermes.stopped == ["run_123"]
    hermes.state = RunState.CANCELLED
    service.iteration()
    assert store.state.jobs["download-id"].status is JobStatus.MANUAL_RESOLVED


def test_source_outside_configured_root_is_not_handed_to_agent(tmp_path: Path) -> None:
    service, radarr, hermes, store, _clock, _source, _output = service_fixture(tmp_path)
    outside = tmp_path / "outside"
    outside.mkdir()
    radarr.records = [queue_record(outside)]

    service.iteration()

    job = store.state.jobs["download-id"]
    assert job.status is JobStatus.NEEDS_ATTENTION
    assert job.failure_kind is FailureKind.SOURCE_INVALID
    assert hermes.instructions == []
