import json
import subprocess
import tempfile
import unittest
from pathlib import Path

from main import (
    CueSplitterError,
    CueSplitterService,
    LidarrClient,
    ManualMatchRequired,
    SourceInvalid,
    StateStore,
    UnflacRunner,
    build_manual_import_files,
    cue_already_split_audio_files,
    inspection_summary,
    is_within,
    output_fingerprint,
    prometheus_metrics,
    read_api_key,
    safe_component,
)


class CueSplitterTests(unittest.TestCase):
    def test_reads_lidarr_api_key(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "config.xml"
            config.write_text(
                "<Config><ApiKey>secret-key</ApiKey></Config>", encoding="utf-8"
            )
            self.assertEqual(read_api_key(config), "secret-key")

    def test_rejects_missing_api_key(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "config.xml"
            config.write_text("<Config />", encoding="utf-8")
            with self.assertRaises(CueSplitterError):
                read_api_key(config)

    def test_path_allowlist(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.assertTrue(is_within(root / "album" / "disc.cue", [root]))
            self.assertFalse(is_within(root.parent / "other" / "disc.cue", [root]))

    def test_safe_component_is_stable_and_bounded(self):
        first = safe_component("lidarr:download/id")
        self.assertEqual(first, safe_component("lidarr:download/id"))
        self.assertNotIn("/", first)
        self.assertLessEqual(len(first), 61)

    def test_output_fingerprint_changes_with_source(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            audio = root / "album.flac"
            audio.write_bytes(b"first")
            first = output_fingerprint(root)
            audio.write_bytes(b"second version")
            self.assertNotEqual(first, output_fingerprint(root))

    def test_unflac_inspection(self):
        payload = [
            {
                "path": "album.cue",
                "audio": [{"path": "/music/album.ape", "tracks": [{}, {}]}],
            }
        ]

        def run(*args, **kwargs):
            return subprocess.CompletedProcess(args[0], 0, json.dumps(payload), "")

        self.assertEqual(UnflacRunner(run).inspect(Path("album.cue")), payload)

    def test_unflac_inspection_failure(self):
        def run(*args, **kwargs):
            return subprocess.CompletedProcess(args[0], 1, "", "bad cue")

        with self.assertRaises(SourceInvalid):
            UnflacRunner(run).inspect(Path("album.cue"))

    def test_detaching_queue_item_retains_download_client_data(self):
        class RecordingClient(LidarrClient):
            def __init__(self):
                super().__init__("http://lidarr", "secret")
                self.request_args = None

            def request(self, method, endpoint, *, query=None, body=None):
                self.request_args = (method, endpoint, query, body)
                return None

        client = RecordingClient()
        client.detach_queue_item(42, blocklist=True)

        method, endpoint, query, body = client.request_args
        self.assertEqual((method, endpoint, body), ("DELETE", "queue/42", None))
        self.assertEqual(query["removeFromClient"], "false")
        self.assertEqual(query["blocklist"], "true")
        self.assertEqual(query["skipRedownload"], "true")

    def test_image_style_inspection_is_eligible(self):
        cue = Path("/music/album.cue")
        payload = [{"audio": [{"path": "/music/album.flac", "tracks": [{}, {}, {}]}]}]
        summary = inspection_summary(cue, payload)
        self.assertTrue(summary["eligible"])
        self.assertEqual(summary["track_count"], 3)

    def test_one_file_per_track_cue_is_not_eligible(self):
        cue = Path("/music/album.cue")
        payload = [
            {
                "audio": [
                    {"path": "/music/01.flac", "tracks": [{}]},
                    {"path": "/music/02.flac", "tracks": [{}]},
                ]
            }
        ]
        self.assertFalse(inspection_summary(cue, payload)["eligible"])

    def test_eac_noncompliant_one_file_per_track_cue_is_already_split(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            cue = root / "album.cue"
            cue.write_text(
                "\n".join(
                    [
                        'FILE "01 - First.wav" WAVE',
                        "  TRACK 01 AUDIO",
                        "    INDEX 01 00:00:00",
                        "  TRACK 02 AUDIO",
                        "    INDEX 00 03:12:34",
                        'FILE "02 - Second.wav" WAVE',
                        "    INDEX 01 00:00:00",
                    ]
                ),
                encoding="utf-8",
            )
            first = root / "01 - First.flac"
            second = root / "02 - Second.flac"
            first.write_bytes(b"flac")
            second.write_bytes(b"flac")

            self.assertEqual(
                cue_already_split_audio_files(cue),
                [first.resolve(), second.resolve()],
            )

    def test_already_split_cue_requires_every_referenced_audio_file(self):
        with tempfile.TemporaryDirectory() as directory:
            cue = Path(directory) / "album.cue"
            cue.write_text(
                'FILE "missing.wav" WAVE\n  TRACK 01 AUDIO\n    INDEX 01 00:00:00\n',
                encoding="utf-8",
            )
            self.assertIsNone(cue_already_split_audio_files(cue))

    def test_image_cue_is_not_classified_as_already_split(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            cue = root / "album.cue"
            cue.write_text(
                "\n".join(
                    [
                        'FILE "album.flac" WAVE',
                        "  TRACK 01 AUDIO",
                        "    INDEX 01 00:00:00",
                        "  TRACK 02 AUDIO",
                        "    INDEX 01 03:12:34",
                    ]
                ),
                encoding="utf-8",
            )
            (root / "album.flac").write_bytes(b"flac")

            self.assertIsNone(cue_already_split_audio_files(cue))

    def test_builds_manual_import_payload(self):
        generated = [Path("/stage/01.flac"), Path("/stage/02.flac")]
        outputs = [
            {
                "path": str(path),
                "artist": {"id": 4},
                "album": {"id": 5},
                "albumReleaseId": 6,
                "tracks": [{"id": index}],
                "quality": {"quality": {"id": 1}},
                "downloadId": "abc",
                "rejections": [],
            }
            for index, path in enumerate(generated, start=10)
        ]
        files = build_manual_import_files(
            outputs, generated, {"artistId": 4, "albumId": 5, "downloadId": "abc"}
        )
        self.assertEqual([item["trackIds"] for item in files], [[10], [11]])
        self.assertTrue(all(item["downloadId"] == "abc" for item in files))

    def test_manual_import_requires_every_generated_file(self):
        generated = [Path("/stage/01.flac"), Path("/stage/02.flac")]
        outputs = [
            {
                "path": "/stage/01.flac",
                "artist": {"id": 4},
                "album": {"id": 5},
                "albumReleaseId": 6,
                "tracks": [{"id": 10}],
                "rejections": [],
            }
        ]
        with self.assertRaises(ManualMatchRequired):
            build_manual_import_files(outputs, generated, {"artistId": 4, "albumId": 5})

    def test_manual_import_rejections_need_attention(self):
        output = {
            "path": "/stage/01.flac",
            "artist": {"id": 4},
            "album": {"id": 5},
            "tracks": [{"id": 10}],
            "rejections": [{"reason": "unknown album"}],
        }
        with self.assertRaises(ManualMatchRequired):
            build_manual_import_files(
                [output], [Path("/stage/01.flac")], {"artistId": 4, "albumId": 5}
            )

    def test_metrics_include_health_state_and_totals(self):
        with tempfile.TemporaryDirectory() as directory:
            store = StateStore(Path(directory) / "state.json")
            store.data["jobs"]["abc"] = {"status": "awaiting_manual_match"}
            store.data["totals"].update(
                success=3, failed=1, ignored=2, manual=1, tracks=24
            )
            metrics = prometheus_metrics(store, True, 1234.0)
            self.assertIn("host_observability_lidarr_cue_splitter_ok 1", metrics)
            self.assertIn(
                'host_observability_lidarr_cue_splitter_jobs{state="awaiting_manual_match"} 1',
                metrics,
            )
            self.assertIn(
                'host_observability_lidarr_cue_splitter_jobs_total{result="success"} 3',
                metrics,
            )
            self.assertIn(
                "host_observability_lidarr_cue_splitter_tracks_total 24", metrics
            )

    def test_completed_download_is_split_imported_and_cleaned(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            download = root / "torrents" / "album"
            download.mkdir(parents=True)
            cue = download / "album.cue"
            audio = download / "album.ape"
            cue.write_text('FILE "album.ape" WAVE\n', encoding="utf-8")
            audio.write_bytes(b"ape")
            record = {
                "status": "completed",
                "protocol": "torrent",
                "downloadId": "abc",
                "outputPath": str(download),
                "title": "Album",
                "artistId": 4,
                "albumId": 5,
            }

            class FakeRunner:
                def inspect(self, cue_path):
                    return [
                        {
                            "audio": [
                                {
                                    "path": str(audio),
                                    "tracks": [{"number": 1}, {"number": 2}],
                                }
                            ]
                        }
                    ]

                def split(self, cue_path, output_dir):
                    paths = [output_dir / "01.flac", output_dir / "02.flac"]
                    for path in paths:
                        path.write_bytes(b"flac")
                    return paths

                def verify_flac(self, path):
                    if not path.exists():
                        raise AssertionError("missing generated file")

            class FakeClient:
                def __init__(self):
                    self.records = [record]
                    self.submitted = []

                def queue(self):
                    return self.records

                def manual_import(self, folder, queue_record):
                    return [
                        {
                            "path": str(path),
                            "artist": {"id": 4},
                            "album": {"id": 5},
                            "albumReleaseId": 6,
                            "tracks": [{"id": index}],
                            "quality": {},
                            "downloadId": "abc",
                            "rejections": [],
                        }
                        for index, path in enumerate(
                            sorted(folder.rglob("*.flac")), start=10
                        )
                    ]

                def submit_manual_import(self, files):
                    self.submitted = files
                    return 7

                def command(self, command_id):
                    return {"id": command_id, "status": "completed"}

            client = FakeClient()
            store = StateStore(root / "state.json")
            now = [1000.0]
            service = CueSplitterService(
                client_factory=lambda: client,
                runner=FakeRunner(),
                store=store,
                allowed_roots=[root / "torrents"],
                work_root=root / "work",
                metrics_file=root / "metrics.prom",
                settle_seconds=0,
                command_timeout_seconds=60,
                missing_queue_confirmations=1,
                now=lambda: now[0],
                sleep=lambda _: None,
            )
            service.iteration()
            now[0] += 1
            service.iteration()
            self.assertEqual(
                store.data["jobs"]["abc"]["status"], "awaiting_queue_removal"
            )
            self.assertEqual(len(client.submitted), 2)
            client.records = []
            now[0] += 1
            service.iteration()
            self.assertEqual(store.data["jobs"]["abc"]["status"], "complete")
            self.assertEqual(store.data["totals"]["success"], 1)
            self.assertEqual(store.data["totals"]["tracks"], 2)
            self.assertFalse((download / "_lidarr-cue-split").exists())
            self.assertTrue(audio.exists())

    def test_non_cue_download_recovers_from_needs_attention(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            download = root / "usenet" / "manual" / "album"
            download.mkdir(parents=True)
            (download / "album.tar").write_bytes(b"tar")
            record = {
                "status": "completed",
                "protocol": "usenet",
                "downloadId": "abc",
                "outputPath": str(download),
            }

            class FakeClient:
                def queue(self):
                    return [record]

            store = StateStore(root / "state.json")
            store.data["jobs"]["abc"] = {
                "download_id": "abc",
                "status": "needs_attention",
                "error": "download path is outside allowed roots",
                "updated_at": 1000.0,
            }
            service = CueSplitterService(
                client_factory=FakeClient,
                runner=object(),
                store=store,
                allowed_roots=[root / "usenet" / "manual"],
                work_root=root / "work",
                metrics_file=root / "metrics.prom",
                settle_seconds=0,
                command_timeout_seconds=60,
                now=lambda: 1001.0,
                sleep=lambda _: None,
            )
            service.iteration()
            self.assertEqual(store.data["jobs"]["abc"]["status"], "ignored")
            self.assertEqual(store.data["jobs"]["abc"]["error"], "")
            self.assertEqual(store.data["totals"]["ignored"], 1)
            service.iteration()
            self.assertEqual(store.data["totals"]["ignored"], 1)

    def test_already_split_cue_recovers_exhausted_job_without_unflac(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            download = root / "torrents" / "album"
            download.mkdir(parents=True)
            (download / "album.cue").write_text(
                "\n".join(
                    [
                        'FILE "01.wav" WAVE',
                        "  TRACK 01 AUDIO",
                        "    INDEX 01 00:00:00",
                        "  TRACK 02 AUDIO",
                        "    INDEX 00 03:12:34",
                        'FILE "02.wav" WAVE',
                        "    INDEX 01 00:00:00",
                    ]
                ),
                encoding="utf-8",
            )
            (download / "01.flac").write_bytes(b"flac")
            (download / "02.flac").write_bytes(b"flac")
            record = {
                "status": "completed",
                "protocol": "torrent",
                "downloadId": "abc",
                "outputPath": str(download),
            }

            class FakeClient:
                def queue(self):
                    return [record]

            class UnexpectedRunner:
                def inspect(self, cue):
                    raise AssertionError(f"unflac should not inspect {cue}")

            store = StateStore(root / "state.json")
            store.data["jobs"]["abc"] = {
                "download_id": "abc",
                "status": "needs_attention",
                "attempts": 3,
                "error": "unflac could not parse EAC cue",
                "updated_at": 1000.0,
            }
            service = CueSplitterService(
                client_factory=FakeClient,
                runner=UnexpectedRunner(),
                store=store,
                allowed_roots=[root / "torrents"],
                work_root=root / "work",
                metrics_file=root / "metrics.prom",
                settle_seconds=0,
                command_timeout_seconds=60,
                now=lambda: 1001.0,
                sleep=lambda _: None,
            )

            service.iteration()
            self.assertEqual(store.data["jobs"]["abc"]["status"], "ignored")
            self.assertEqual(store.data["jobs"]["abc"]["error"], "")
            self.assertEqual(store.data["totals"]["ignored"], 1)
            service.iteration()
            self.assertEqual(store.data["totals"]["ignored"], 1)

    def test_manual_match_preserves_generated_tracks_without_retrying_split(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            download = root / "torrents" / "album"
            download.mkdir(parents=True)
            cue = download / "album.cue"
            audio = download / "album.ape"
            cue.write_text('FILE "album.ape" WAVE\n', encoding="utf-8")
            audio.write_bytes(b"ape")
            record = {
                "id": 42,
                "status": "completed",
                "protocol": "torrent",
                "downloadId": "abc",
                "outputPath": str(download),
                "title": "Album",
                "artistId": 4,
                "albumId": 5,
            }

            class FakeRunner:
                def __init__(self):
                    self.splits = 0

                def inspect(self, cue_path):
                    return [
                        {
                            "audio": [
                                {
                                    "path": str(audio),
                                    "tracks": [{"number": 1}, {"number": 2}],
                                }
                            ]
                        }
                    ]

                def split(self, cue_path, output_dir):
                    self.splits += 1
                    paths = [output_dir / "01.flac", output_dir / "02.flac"]
                    for path in paths:
                        path.write_bytes(b"flac")
                    return paths

                def verify_flac(self, path):
                    self.assert_path_exists(path)

                @staticmethod
                def assert_path_exists(path):
                    if not path.exists():
                        raise AssertionError("missing generated file")

            class FakeClient:
                def __init__(self):
                    self.records = [record]
                    self.detached = []

                def queue(self):
                    return self.records

                def manual_import(self, folder, queue_record):
                    return [
                        {
                            "path": str(path),
                            "artist": {"id": 4},
                            "album": {"id": 5},
                            "tracks": [{"id": index}],
                            "rejections": [{"reason": "album match is too weak"}],
                        }
                        for index, path in enumerate(
                            sorted(folder.rglob("*.flac")), start=10
                        )
                    ]

                def detach_queue_item(self, queue_id, *, blocklist):
                    self.detached.append((queue_id, blocklist))

            client = FakeClient()
            runner = FakeRunner()
            store = StateStore(root / "state.json")
            now = [1000.0]
            service = CueSplitterService(
                client_factory=lambda: client,
                runner=runner,
                store=store,
                allowed_roots=[root / "torrents"],
                work_root=root / "work",
                metrics_file=root / "metrics.prom",
                settle_seconds=0,
                command_timeout_seconds=60,
                now=lambda: now[0],
                sleep=lambda _: None,
            )

            service.iteration()
            now[0] += 1
            service.iteration()
            job = store.data["jobs"]["abc"]
            ready_root = Path(job["ready_root"])
            self.assertEqual(job["status"], "awaiting_manual_match")
            self.assertEqual(len(list(ready_root.rglob("*.flac"))), 2)
            self.assertEqual(store.data["totals"]["manual"], 1)
            self.assertEqual(client.detached, [])
            self.assertTrue(audio.exists())

            service.iteration()
            self.assertEqual(runner.splits, 1)
            client.records = []
            for _ in range(3):
                now[0] += 30
                service.iteration()
            self.assertEqual(job["status"], "manual_resolved")
            self.assertEqual(len(list(ready_root.rglob("*.flac"))), 2)

    def test_transient_empty_queue_does_not_dismiss_problem_job(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            download = root / "torrents" / "album"
            download.mkdir(parents=True)
            record = {
                "id": 42,
                "status": "completed",
                "protocol": "torrent",
                "downloadId": "abc",
                "outputPath": str(download),
            }

            class FakeClient:
                def __init__(self):
                    self.records = []

                def queue(self):
                    return self.records

            client = FakeClient()
            store = StateStore(root / "state.json")
            job = {
                "download_id": "abc",
                "status": "failed",
                "attempts": 1,
                "error": "temporary source failure",
                "updated_at": 1000.0,
            }
            store.data["jobs"]["abc"] = job
            now = [1001.0]
            service = CueSplitterService(
                client_factory=lambda: client,
                runner=object(),
                store=store,
                allowed_roots=[root / "torrents"],
                work_root=root / "work",
                metrics_file=root / "metrics.prom",
                settle_seconds=0,
                command_timeout_seconds=60,
                now=lambda: now[0],
                sleep=lambda _: None,
            )

            service.iteration()
            self.assertEqual(job["status"], "failed")
            self.assertEqual(job["missing_queue_observations"], 1)
            client.records = [record]
            service.iteration()
            self.assertEqual(job["status"], "failed")
            self.assertNotIn("missing_queue_observations", job)

    def test_legacy_post_split_failure_becomes_manual_work(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            download = root / "torrents" / "album"
            ready_root = download / "_lidarr-cue-split" / "abc"
            ready_root.mkdir(parents=True)
            generated = ready_root / "01.flac"
            generated.write_bytes(b"flac")
            record = {
                "status": "completed",
                "protocol": "torrent",
                "downloadId": "abc",
                "outputPath": str(download),
            }

            class FakeClient:
                def queue(self):
                    return [record]

            store = StateStore(root / "state.json")
            job = {
                "download_id": "abc",
                "status": "needs_attention",
                "ready_root": str(ready_root),
                "error": "Lidarr rejected the generated track",
                "updated_at": 1000.0,
            }
            store.data["jobs"]["abc"] = job
            service = CueSplitterService(
                client_factory=FakeClient,
                runner=object(),
                store=store,
                allowed_roots=[root / "torrents"],
                work_root=root / "work",
                metrics_file=root / "metrics.prom",
                settle_seconds=0,
                command_timeout_seconds=60,
                now=lambda: 1001.0,
                sleep=lambda _: None,
            )

            service.iteration()
            self.assertEqual(job["status"], "awaiting_manual_match")
            self.assertTrue(generated.exists())
            self.assertEqual(store.data["totals"]["manual"], 1)

    def test_problem_job_is_dismissed_and_expires_after_leaving_queue(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)

            class FakeClient:
                def queue(self):
                    return []

            store = StateStore(root / "state.json")
            store.data["jobs"]["abc"] = {
                "download_id": "abc",
                "status": "needs_attention",
                "error": "malformed cue",
                "updated_at": 1000.0,
            }
            now = [1001.0]
            service = CueSplitterService(
                client_factory=FakeClient,
                runner=object(),
                store=store,
                allowed_roots=[root / "torrents"],
                work_root=root / "work",
                metrics_file=root / "metrics.prom",
                settle_seconds=0,
                command_timeout_seconds=60,
                missing_queue_confirmations=1,
                now=lambda: now[0],
                sleep=lambda _: None,
            )

            service.iteration()
            self.assertEqual(store.data["jobs"]["abc"]["status"], "dismissed")
            self.assertEqual(store.data["jobs"]["abc"]["error"], "malformed cue")
            metrics = prometheus_metrics(store, True, now[0])
            self.assertIn(
                'host_observability_lidarr_cue_splitter_jobs{state="dismissed"} 1',
                metrics,
            )
            self.assertIn(
                'host_observability_lidarr_cue_splitter_jobs{state="needs_attention"} 0',
                metrics,
            )

            now[0] += 7 * 86400
            service.iteration()
            self.assertNotIn("abc", store.data["jobs"])

    def test_exhausted_invalid_source_is_detached_but_files_are_retained(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            download = root / "torrents" / "album"
            download.mkdir(parents=True)
            cue = download / "album.cue"
            cue.write_text("malformed cue", encoding="utf-8")
            record = {
                "id": 42,
                "status": "completed",
                "protocol": "torrent",
                "downloadId": "abc",
                "outputPath": str(download),
            }

            class FakeClient:
                def __init__(self):
                    self.detached = []

                def queue(self):
                    return [record]

                def detach_queue_item(self, queue_id, *, blocklist):
                    self.detached.append((queue_id, blocklist))

            class FailingRunner:
                def __init__(self):
                    self.inspections = 0

                def inspect(self, cue):
                    self.inspections += 1
                    raise SourceInvalid("malformed cue")

            client = FakeClient()
            runner = FailingRunner()
            store = StateStore(root / "state.json")
            now = [1000.0]
            service = CueSplitterService(
                client_factory=lambda: client,
                runner=runner,
                store=store,
                allowed_roots=[root / "torrents"],
                work_root=root / "work",
                metrics_file=root / "metrics.prom",
                settle_seconds=0,
                command_timeout_seconds=60,
                now=lambda: now[0],
                sleep=lambda _: None,
            )

            service.iteration()
            self.assertEqual(store.data["jobs"]["abc"]["attempts"], 1)
            service.iteration()
            self.assertEqual(runner.inspections, 1)

            for attempt in (2, 3):
                now[0] += 300
                service.iteration()
                self.assertEqual(store.data["jobs"]["abc"]["attempts"], attempt)

            now[0] += 300
            service.iteration()
            self.assertEqual(runner.inspections, 3)
            self.assertEqual(store.data["jobs"]["abc"]["status"], "source_invalid")
            self.assertEqual(store.data["totals"]["failed"], 3)
            self.assertEqual(store.data["totals"]["source_invalid"], 1)
            self.assertEqual(client.detached, [(42, True)])
            self.assertTrue(cue.exists())
            service.iteration()
            self.assertEqual(runner.inspections, 3)
            self.assertEqual(client.detached, [(42, True)])

    def test_changed_source_gets_fresh_retries_before_detachment(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            download = root / "torrents" / "album"
            download.mkdir(parents=True)
            cue = download / "album.cue"
            cue.write_text("first malformed cue", encoding="utf-8")
            failed_fingerprint = output_fingerprint(download)
            cue.write_text("changed malformed cue", encoding="utf-8")
            record = {
                "id": 42,
                "status": "completed",
                "protocol": "torrent",
                "downloadId": "abc",
                "outputPath": str(download),
            }

            class FakeClient:
                def __init__(self):
                    self.detached = []

                def queue(self):
                    return [record]

                def detach_queue_item(self, queue_id, *, blocklist):
                    self.detached.append((queue_id, blocklist))

            class FailingRunner:
                def inspect(self, cue_path):
                    raise SourceInvalid("malformed cue")

            client = FakeClient()
            store = StateStore(root / "state.json")
            job = {
                "download_id": "abc",
                "status": "failed",
                "attempts": 3,
                "failure_kind": "source_invalid",
                "failure_fingerprint": failed_fingerprint,
                "updated_at": 1000.0,
            }
            store.data["jobs"]["abc"] = job
            service = CueSplitterService(
                client_factory=lambda: client,
                runner=FailingRunner(),
                store=store,
                allowed_roots=[root / "torrents"],
                work_root=root / "work",
                metrics_file=root / "metrics.prom",
                settle_seconds=0,
                command_timeout_seconds=60,
                now=lambda: 2000.0,
                sleep=lambda _: None,
            )

            service.iteration()
            self.assertEqual(job["status"], "failed")
            self.assertEqual(job["attempts"], 1)
            self.assertEqual(client.detached, [])

    def test_unavailable_source_is_detached_without_blocklisting(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            missing_download = root / "torrents" / "missing"
            record = {
                "id": 42,
                "status": "completed",
                "protocol": "torrent",
                "downloadId": "abc",
                "outputPath": str(missing_download),
            }

            class FakeClient:
                def __init__(self):
                    self.detached = []

                def queue(self):
                    return [record]

                def detach_queue_item(self, queue_id, *, blocklist):
                    self.detached.append((queue_id, blocklist))

            client = FakeClient()
            store = StateStore(root / "state.json")
            job = {
                "download_id": "abc",
                "status": "failed",
                "attempts": 3,
                "failure_kind": "source_unavailable",
                "error": "download path does not exist",
                "updated_at": 1000.0,
            }
            store.data["jobs"]["abc"] = job
            service = CueSplitterService(
                client_factory=lambda: client,
                runner=object(),
                store=store,
                allowed_roots=[root / "torrents"],
                work_root=root / "work",
                metrics_file=root / "metrics.prom",
                settle_seconds=0,
                command_timeout_seconds=60,
                now=lambda: 2000.0,
                sleep=lambda _: None,
            )

            service.iteration()
            self.assertEqual(job["status"], "source_unavailable")
            self.assertEqual(client.detached, [(42, False)])


if __name__ == "__main__":
    unittest.main()
