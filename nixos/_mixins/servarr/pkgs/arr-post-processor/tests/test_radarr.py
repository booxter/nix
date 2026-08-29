from __future__ import annotations

import json
import subprocess
import tempfile
import unittest
from pathlib import Path

from arr_post_processor.errors import NeedsAttention, SourceInvalid
from arr_post_processor.media_join import (
    CommandJoinBackend,
    JoinPlan,
    MediaProbe,
    build_join_plan,
    download_fingerprint,
    ordered_primary_parts,
    prepare_joined_media,
    safe_output_name,
)
from arr_post_processor.radarr_models import (
    CommandStatus,
    RadarrManualImportCandidate,
    RadarrManualImportFile,
    RadarrMovie,
    RadarrQueueRecord,
)
from arr_post_processor.radarr_service import RadarrJoinService
from arr_post_processor.state import StateStore


SIGNATURE = (("video", "h264", 1920, 1080, None), ("audio", "aac", None, None, 2))


def probe(duration: float, signature=SIGNATURE) -> MediaProbe:
    return MediaProbe(duration_seconds=duration, signature=signature)


def movie(runtime: int = 120) -> RadarrMovie:
    return RadarrMovie(id=42, title="Test Movie", year=2020, runtime=runtime)


def record(path: Path, **changes: object) -> RadarrQueueRecord:
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
        "quality": {"quality": {"id": 7, "name": "Bluray-1080p"}},
    }
    values.update(changes)
    return RadarrQueueRecord.model_validate(values)


class FakeBackend:
    def __init__(self, probes: dict[Path, MediaProbe] | None = None):
        self.probes = probes or {}
        self.joined: list[tuple[tuple[Path, ...], Path]] = []

    def probe(self, path: Path) -> MediaProbe:
        return self.probes[path.resolve()]

    def join(self, parts: tuple[Path, ...], output: Path) -> None:
        output.write_bytes(b"joined")
        self.joined.append((parts, output))
        source = sum(self.probes[path.resolve()].duration_seconds for path in parts)
        self.probes[output.resolve()] = probe(source, self.probes[parts[0].resolve()].signature)


def make_parts(root: Path, names: list[str], durations: list[float]) -> FakeBackend:
    probes = {}
    for name, duration in zip(names, durations):
        path = root / name
        path.write_bytes(b"media")
        probes[path.resolve()] = probe(duration)
    return FakeBackend(probes)


class FilenamePlanningTests(unittest.TestCase):
    def test_live_naming_families_are_ordered(self):
        cases = [
            (["movie.disc2.mkv", "movie.disc1.mkv"], ["movie.disc1.mkv", "movie.disc2.mkv"]),
            (["Movie CD2.avi", "Movie CD1.avi"], ["Movie CD1.avi", "Movie CD2.avi"]),
            (
                [
                    "Movie Part.2b.mkv",
                    "Movie Part.1a.mkv",
                    "Movie Part.2a.mkv",
                    "Movie Part.1b.mkv",
                ],
                [
                    "Movie Part.1a.mkv",
                    "Movie Part.1b.mkv",
                    "Movie Part.2a.mkv",
                    "Movie Part.2b.mkv",
                ],
            ),
            (
                ["48991_03_1080p.mp4", "48991_01_1080p.mp4", "48991_02_1080p.mp4"],
                ["48991_01_1080p.mp4", "48991_02_1080p.mp4", "48991_03_1080p.mp4"],
            ),
            (
                ["Title Chapter 3.mp4", "Title.mp4", "Title Chapter 2.mp4"],
                ["Title.mp4", "Title Chapter 2.mp4", "Title Chapter 3.mp4"],
            ),
        ]
        for names, expected in cases:
            with self.subTest(names=names), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                make_parts(root, names, [60.0] * len(names))
                actual = ordered_primary_parts(root)
                self.assertIsNotNone(actual)
                self.assertEqual([path.name for path in actual or ()], expected)

    def test_extras_are_excluded_but_seasons_and_nested_video_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            make_parts(root, ["Scene 1.mp4", "Scene 2.mp4", "bonus.mp4", "bts.mp4"], [1] * 4)
            self.assertEqual(
                [path.name for path in ordered_primary_parts(root) or ()],
                ["Scene 1.mp4", "Scene 2.mp4"],
            )
        with tempfile.TemporaryDirectory(prefix="Season 2 ") as directory:
            root = Path(directory)
            make_parts(root, ["Show S02E01.mkv", "Show S02E02.mkv"], [1, 1])
            self.assertIsNone(ordered_primary_parts(root))
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            make_parts(root, ["Scene 1.mp4", "Scene 2.mp4"], [1, 1])
            nested = root / "extras"
            nested.mkdir()
            make_parts(nested, ["trailer.mp4"], [1])
            self.assertIsNone(ordered_primary_parts(root))

    def test_plan_requires_runtime_and_stream_compatibility(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            backend = make_parts(root, ["Scene 1.mp4", "Scene 2.mp4"], [3600, 3600])
            plan = build_join_plan(record(root), movie(), [root], backend)
            self.assertIsNotNone(plan)
            self.assertEqual(plan.parts[0].name, "Scene 1.mp4")
            self.assertEqual(plan.output_extension, "mp4")
            self.assertEqual(len(plan.fingerprint), 64)

            self.assertIsNone(build_join_plan(record(root), movie(60), [root], backend))
            backend.probes[(root / "Scene 2.mp4").resolve()] = probe(
                3600, (("video", "hevc", 1920, 1080, None),)
            )
            with self.assertRaisesRegex(SourceInvalid, "stream layouts"):
                build_join_plan(record(root), movie(), [root], backend)

    def test_plan_rejects_disc_images_and_paths_outside_roots(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            backend = make_parts(root, ["Part 1.mkv", "Part 2.mkv"], [3600, 3600])
            (root / "BDMV").mkdir()
            self.assertIsNone(build_join_plan(record(root), movie(), [root], backend))
            with self.assertRaisesRegex(NeedsAttention, "outside allowed roots"):
                build_join_plan(record(root), movie(), [root / "other"], backend)


class CommandBackendTests(unittest.TestCase):
    def test_probe_and_join_commands(self):
        calls: list[list[str]] = []

        def run(argv, **_kwargs):
            calls.append(argv)
            if argv[0] == "ffprobe":
                return subprocess.CompletedProcess(
                    argv,
                    0,
                    json.dumps(
                        {
                            "streams": [
                                {
                                    "codec_name": "h264",
                                    "codec_type": "video",
                                    "width": 1920,
                                    "height": 1080,
                                }
                            ],
                            "format": {"duration": "12.5"},
                        }
                    ),
                    "",
                )
            return subprocess.CompletedProcess(argv, 0, "", "")

        backend = CommandJoinBackend(ffprobe="ffprobe", joiner="joiner", run=run)
        self.assertEqual(backend.probe(Path("part.mp4")).duration_seconds, 12.5)
        backend.join((Path("one.mp4"), Path("two.mp4")), Path("out.mp4"))
        self.assertEqual(
            calls[-1],
            ["joiner", "--part", "one.mp4", "--part", "two.mp4", "--output", "out.mp4"],
        )

    def test_command_failures_are_classified(self):
        def failed(argv, **_kwargs):
            return subprocess.CompletedProcess(argv, 1, "", "broken")

        backend = CommandJoinBackend(ffprobe="ffprobe", joiner="joiner", run=failed)
        with self.assertRaisesRegex(SourceInvalid, "ffprobe failed"):
            backend.probe(Path("part.mp4"))
        with self.assertRaisesRegex(SourceInvalid, "media join failed"):
            backend.join((Path("one.mp4"), Path("two.mp4")), Path("out.mp4"))

    def test_invalid_probe_payload_is_rejected(self):
        def run(argv, **_kwargs):
            return subprocess.CompletedProcess(argv, 0, "{}", "")

        backend = CommandJoinBackend(ffprobe="ffprobe", joiner="joiner", run=run)
        with self.assertRaisesRegex(SourceInvalid, "invalid media metadata"):
            backend.probe(Path("part.mp4"))


class PreparedMediaTests(unittest.TestCase):
    def test_joined_media_is_verified(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source"
            source.mkdir()
            work = root / "work"
            work.mkdir()
            backend = make_parts(source, ["Disc 1.mkv", "Disc 2.mkv"], [60, 70])
            plan = JoinPlan(
                parts=tuple(sorted(backend.probes)),
                probes=(probe(60), probe(70)),
                fingerprint="fingerprint",
                expected_duration_seconds=130,
                output_extension="mkv",
            )
            output = prepare_joined_media(record(source), movie(), plan, work, backend)
            self.assertTrue(output.exists())
            self.assertIn("Test.Movie.2020.1080p", output.name)
            self.assertNotEqual(download_fingerprint(source), "")
            self.assertEqual(safe_output_name(record(source), movie(), "mkv"), output.name)

            class BadDurationBackend(FakeBackend):
                def join(self, parts, destination):
                    destination.write_bytes(b"joined")
                    self.probes[destination.resolve()] = probe(1)

            bad_backend = BadDurationBackend(backend.probes)
            with self.assertRaisesRegex(SourceInvalid, "duration"):
                prepare_joined_media(record(source), movie(), plan, work, bad_backend)


class FakeRadarr:
    def __init__(self, queue_record: RadarrQueueRecord, backend: FakeBackend):
        self.records = [queue_record]
        self.queue_record = queue_record
        self.backend = backend
        self.imported: RadarrManualImportFile | None = None

    def queue(self):
        return self.records

    def movie(self, movie_id):
        assert movie_id == 42
        return movie()

    def manual_import(self, folder, queue_record):
        output = next(folder.iterdir())
        return [
            RadarrManualImportCandidate(
                path=output,
                movie=movie(),
                quality=queue_record.quality,
                download_id=queue_record.download_id,
            )
        ]

    def submit_manual_import(self, file):
        self.imported = file
        return 9

    def command(self, command_id):
        return CommandStatus(id=command_id, status="completed")


class RadarrServiceTests(unittest.TestCase):
    def test_full_join_import_and_cleanup_lifecycle(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source"
            source.mkdir()
            work = root / "work"
            work.mkdir()
            backend = make_parts(source, ["Scene 1.mp4", "Scene 2.mp4"], [3600, 3600])
            queue_record = record(source)
            client = FakeRadarr(queue_record, backend)
            current = [1000.0]
            store = StateStore(root / "state.json")
            service = RadarrJoinService(
                client_factory=lambda: client,
                backend=backend,
                store=store,
                allowed_roots=[root],
                work_root=work,
                metrics_file=root / "metrics.prom",
                settle_seconds=30,
                command_timeout_seconds=10,
                missing_queue_confirmations=2,
                now=lambda: current[0],
                sleep=lambda _seconds: None,
            )

            service.iteration()
            self.assertEqual(store.state.jobs["download-id"].status, "settling")
            current[0] += 31
            service.iteration()
            job = store.state.jobs["download-id"]
            self.assertEqual(job.status, "awaiting_queue_removal")
            self.assertIsNotNone(client.imported)
            self.assertTrue(job.ready_root and job.ready_root.exists())

            client.records = []
            service.iteration()
            service.iteration()
            self.assertEqual(job.status, "complete")
            self.assertFalse(job.ready_root and job.ready_root.exists())
            self.assertEqual(store.state.totals.success, 1)
            self.assertEqual(store.state.totals.tracks, 2)

            service.write_metrics(ok=True)
            metrics = (root / "metrics.prom").read_text(encoding="utf-8")
            self.assertIn("host_observability_radarr_multipart_joiner_ok 1.0", metrics)
            self.assertIn(
                'host_observability_radarr_multipart_joiner_jobs_total{result="success"} 1.0',
                metrics,
            )
            self.assertNotIn("host_observability_lidarr_cue_splitter", metrics)

    def test_ineligible_and_ambiguous_downloads_are_not_joined(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source"
            source.mkdir()
            backend = make_parts(source, ["random-a.mp4", "random-b.mp4"], [3600, 3600])
            queue_record = record(source)
            client = FakeRadarr(queue_record, backend)
            current = [100.0]
            store = StateStore(root / "state.json")
            service = RadarrJoinService(
                client_factory=lambda: client,
                backend=backend,
                store=store,
                allowed_roots=[root],
                work_root=root / "work",
                metrics_file=root / "metrics.prom",
                settle_seconds=0,
                command_timeout_seconds=1,
                now=lambda: current[0],
            )
            service.iteration()
            service.iteration()
            self.assertEqual(store.state.jobs["download-id"].status, "ignored")
            self.assertFalse(backend.joined)
            self.assertFalse(
                service.eligible_record(record(source, tracked_download_state="importPending"))
            )


if __name__ == "__main__":
    unittest.main()
