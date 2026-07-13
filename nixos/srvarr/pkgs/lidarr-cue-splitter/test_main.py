import json
import subprocess
import tempfile
import unittest
from pathlib import Path

from main import (
    CueSplitterError,
    CueSplitterService,
    NeedsAttention,
    StateStore,
    UnflacRunner,
    build_manual_import_files,
    inspection_summary,
    is_within,
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

        with self.assertRaises(CueSplitterError):
            UnflacRunner(run).inspect(Path("album.cue"))

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
        with self.assertRaises(NeedsAttention):
            build_manual_import_files(outputs, generated, {"artistId": 4, "albumId": 5})

    def test_manual_import_rejections_need_attention(self):
        output = {
            "path": "/stage/01.flac",
            "artist": {"id": 4},
            "album": {"id": 5},
            "tracks": [{"id": 10}],
            "rejections": [{"reason": "unknown album"}],
        }
        with self.assertRaises(NeedsAttention):
            build_manual_import_files(
                [output], [Path("/stage/01.flac")], {"artistId": 4, "albumId": 5}
            )

    def test_metrics_include_health_state_and_totals(self):
        with tempfile.TemporaryDirectory() as directory:
            store = StateStore(Path(directory) / "state.json")
            store.data["jobs"]["abc"] = {"status": "needs_attention"}
            store.data["totals"].update(success=3, failed=1, ignored=2, tracks=24)
            metrics = prometheus_metrics(store, True, 1234.0)
            self.assertIn("host_observability_lidarr_cue_splitter_ok 1", metrics)
            self.assertIn(
                'host_observability_lidarr_cue_splitter_jobs{state="needs_attention"} 1',
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


if __name__ == "__main__":
    unittest.main()
