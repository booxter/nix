from __future__ import annotations

import json
from collections.abc import Iterator
from pathlib import Path
from uuid import UUID

from arr_post_processor.errors import PostProcessorError
from arr_post_processor.lidarr_agent_service import LidarrAgentService
from arr_post_processor.lidarr_agent_state import FailureKind, JobStatus, RepairStateStore
from arr_post_processor.models import (
    AlbumCatalog,
    CommandStatus,
    ManualImportCandidate,
    ManualImportFile,
    QueueRecord,
)
from arr_post_processor.repair_source import SourceRoot
from hermes_runs.client import JsonObject, RunState, RunStatus, RunSummary, StopResult

ATTEMPT_ID = UUID("11111111-2222-3333-4444-555555555555")


class Clock:
    value = 1000.0

    def __call__(self) -> float:
        return self.value


class FakeHermes:
    def __init__(self) -> None:
        self.instructions: list[str] = []
        self.state = RunState.RUNNING
        self.stopped: list[str] = []

    def start_run(self, instruction: str) -> str:
        self.instructions.append(instruction)
        return "run-1"

    def get_run(self, run_id: str) -> RunStatus:
        raw: JsonObject = {"run_id": run_id, "status": self.state.value}
        return RunStatus(
            run_id=run_id,
            state=self.state,
            created_at=1000,
            updated_at=1001,
            model="lidarr-repair",
            last_event="",
            output="",
            error="",
            usage={},
            raw=raw,
        )

    def stop_run(self, run_id: str) -> StopResult:
        self.stopped.append(run_id)
        return StopResult(
            run_id=run_id,
            state=RunState.STOPPING,
            raw={"run_id": run_id, "status": "stopping"},
        )

    def list_runs(self, limit: int) -> list[RunSummary]:
        return []

    def watch_run(self, run_id: str) -> Iterator[JsonObject]:
        yield from ()

    def approve_run(self, run_id: str, choice: str, resolve_all: bool) -> JsonObject:
        raise AssertionError("autonomous repairs cannot be approved")


class FakeVerifier:
    def __init__(self) -> None:
        self.verified: list[Path] = []

    def verify(self, path: Path) -> None:
        self.verified.append(path)


class FakeLidarr:
    def __init__(self, record: QueueRecord) -> None:
        self.records = [record]
        self.import_candidates: list[ManualImportCandidate] = []
        self.imported: list[ManualImportFile] | None = None
        self.command_status = CommandStatus(id=12, status="started")
        self.catalog_errors: dict[int, PostProcessorError] = {}

    def queue(self) -> list[QueueRecord]:
        return self.records

    def album_catalog(self, album_id: int) -> AlbumCatalog:
        if error := self.catalog_errors.get(album_id):
            raise error
        return catalog()

    def manual_import(self, folder: Path, record: QueueRecord) -> list[ManualImportCandidate]:
        return self.import_candidates

    def submit_manual_import(self, files: list[ManualImportFile]) -> int:
        self.imported = files
        return 12

    def command(self, command_id: int) -> CommandStatus:
        assert command_id == 12
        return self.command_status


def catalog() -> AlbumCatalog:
    return AlbumCatalog.model_validate(
        {
            "album": {
                "id": 8,
                "title": "Album",
                "artistId": 7,
                "artist": {"id": 7, "artistName": "Artist"},
                "releases": [
                    {
                        "id": 9,
                        "title": "Album",
                        "mediumCount": 1,
                        "trackCount": 2,
                        "duration": 360000,
                    }
                ],
            },
            "releases": [
                {
                    "release": {
                        "id": 9,
                        "title": "Album",
                        "mediumCount": 1,
                        "trackCount": 2,
                        "duration": 360000,
                    },
                    "tracks": [
                        {
                            "id": 10,
                            "title": "One",
                            "mediumNumber": 1,
                            "trackNumber": 1,
                            "absoluteTrackNumber": 1,
                            "duration": 180000,
                        },
                        {
                            "id": 11,
                            "title": "Two",
                            "mediumNumber": 1,
                            "trackNumber": 2,
                            "absoluteTrackNumber": 2,
                            "duration": 180000,
                        },
                    ],
                }
            ],
        }
    )


def fixture(tmp_path: Path, *, shadow: bool = True):
    source_root = tmp_path / "downloads"
    source = source_root / "Artist - Album"
    source.mkdir(parents=True)
    (source / "album.flac").write_bytes(b"source")
    (source / "album.cue").write_text("cue")
    record = QueueRecord.model_validate(
        {
            "id": 1,
            "downloadId": "download-1",
            "outputPath": str(source),
            "title": "Artist - Album",
            "status": "completed",
            "protocol": "torrent",
            "artistId": 7,
            "albumId": 8,
            "trackedDownloadStatus": "warning",
            "trackedDownloadState": "importPending",
        }
    )
    client = FakeLidarr(record)
    hermes = FakeHermes()
    verifier = FakeVerifier()
    store = RepairStateStore(tmp_path / "state.json")
    clock = Clock()
    service = LidarrAgentService(
        client_factory=lambda: client,
        hermes=hermes,
        store=store,
        source_roots=(SourceRoot(name="torrents", host_path=source_root),),
        output_root=tmp_path / "output",
        audit_root=tmp_path / "audit",
        metrics_file=tmp_path / "metrics.prom",
        verifier=verifier,
        settle_seconds=60,
        agent_timeout_seconds=3600,
        command_timeout_seconds=600,
        shadow=shadow,
        now=clock,
        uuid_factory=lambda: ATTEMPT_ID,
    )
    return service, client, hermes, store, clock, source, verifier


def start(service: LidarrAgentService, store: RepairStateStore, clock: Clock) -> Path:
    service.iteration()
    clock.value += 60
    service.iteration()
    job = store.state.jobs["download-1"]
    assert job.status is JobStatus.AGENT_RUNNING
    assert job.task_root is not None
    return job.task_root


def write_result(store: RepairStateStore) -> None:
    job = store.state.jobs["download-1"]
    assert job.task_root is not None
    for name in ("01.flac", "02.flac"):
        (job.task_root / name).write_bytes(b"audio")
        (job.task_root / name).chmod(0o640)
    (job.task_root / "report.md").write_text("# report\n")
    (job.task_root / "result.json").write_text(
        json.dumps(
            {
                "schema_version": 1,
                "attempt_id": str(ATTEMPT_ID),
                "download_id": "download-1",
                "source_fingerprint": job.source_fingerprint,
                "outcome": "repaired",
                "release_id": 9,
                "files": [
                    {"candidate": "01.flac", "expected_track_ids": [10]},
                    {"candidate": "02.flac", "expected_track_ids": [11]},
                ],
                "reason": "split image CUE",
            }
        )
    )


def test_shadow_run_stops_after_validating_output(tmp_path: Path) -> None:
    service, client, hermes, store, clock, source, verifier = fixture(tmp_path)
    task_root = start(service, store, clock)
    write_result(store)
    hermes.state = RunState.COMPLETED

    service.iteration()
    service.iteration()

    job = store.state.jobs["download-1"]
    assert job.status is JobStatus.READY
    assert len(verifier.verified) == 2
    assert client.imported is None
    assert task_root.exists()
    assert not (source / "_arr-post-processor").exists()


def test_source_change_stops_active_agent(tmp_path: Path) -> None:
    service, _client, hermes, store, clock, source, _verifier = fixture(tmp_path)
    start(service, store, clock)
    (source / "album.cue").write_text("changed")

    service.iteration()

    assert store.state.jobs["download-1"].status is JobStatus.AGENT_STOPPING
    assert hermes.stopped == ["run-1"]


def test_invalid_catalog_does_not_block_next_release(tmp_path: Path) -> None:
    service, client, hermes, store, clock, source, _verifier = fixture(tmp_path)
    second_source = source.parent / "Artist - Other Album"
    second_source.mkdir()
    (second_source / "album.flac").write_bytes(b"source")
    client.records.append(
        client.records[0].model_copy(
            update={
                "download_id": "download-2",
                "output_path": second_source,
                "title": "Artist - Other Album",
                "album_id": 9,
            }
        )
    )
    client.catalog_errors[8] = PostProcessorError("invalid catalog")

    service.iteration()
    clock.value += 60
    service.iteration()
    service.iteration()

    first = store.state.jobs["download-1"]
    assert first.status is JobStatus.NEEDS_ATTENTION
    assert first.failure_kind is FailureKind.SOURCE_INVALID
    assert store.state.jobs["download-2"].status is JobStatus.AGENT_RUNNING
    assert len(hermes.instructions) == 1


def test_active_run_stages_matches_imports_and_cleans(tmp_path: Path) -> None:
    service, client, hermes, store, clock, source, _verifier = fixture(tmp_path, shadow=False)
    task_root = start(service, store, clock)
    write_result(store)
    hermes.state = RunState.COMPLETED
    service.iteration()

    service.iteration()
    job = store.state.jobs["download-1"]
    assert job.status is JobStatus.STAGED
    assert job.handoff_root is not None
    staged = [item.staged for item in job.files]
    assert all(path is not None and path.is_relative_to(source) for path in staged)
    client.import_candidates = [
        ManualImportCandidate.model_validate(
            {
                "path": str(item.staged),
                "artist": {"id": 7},
                "album": {"id": 8},
                "albumReleaseId": 9,
                "tracks": [{"id": item.expected_track_ids[0]}],
                "quality": {},
                "downloadId": "download-1",
            }
        )
        for item in job.files
    ]

    service.iteration()
    assert job.status is JobStatus.IMPORTING
    assert client.imported is not None
    assert all(item.disable_release_switching for item in client.imported)

    client.command_status = CommandStatus(id=12, status="completed")
    service.iteration()
    assert job.status is JobStatus.AWAITING_QUEUE_REMOVAL
    client.records = []
    service.iteration()
    service.iteration()
    service.iteration()

    assert job.status is JobStatus.COMPLETE
    assert not task_root.exists()
    assert not (source / "_arr-post-processor").exists()
    assert (tmp_path / "audit" / str(ATTEMPT_ID) / "result.json").is_file()
    assert store.state.totals.tracks == 2
