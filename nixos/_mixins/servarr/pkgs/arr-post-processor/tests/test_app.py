import base64
import io
import json
import os
import subprocess
import tarfile
import tempfile
import unittest
import urllib.parse
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import Thread
from typing import Iterator

from aiopyarr.models.const import ProtocolType
from arr_post_processor.app import parse_source_roots
from arr_post_processor.archive import ArchiveMember, ArchiveTransform, NativeArchiveBackend
from arr_post_processor.config import read_api_key, read_environment_value
from arr_post_processor.errors import ManualMatchRequired, PostProcessorError, SourceInvalid
from arr_post_processor.lidarr import LidarrClient
from arr_post_processor.lidarr_pipeline import CueTransform, LidarrPipeline
from arr_post_processor.lidarr_service import LidarrPostProcessorService
from arr_post_processor.media import (
    UnflacRunner,
    build_manual_import_files,
    cue_already_split_audio_files,
    inspection_summary,
    is_within,
    output_fingerprint,
    safe_component,
)
from arr_post_processor.metrics import render_metrics
from arr_post_processor.models import (
    CommandStatus,
    ManualImportCandidate,
    ManualImportFile,
    QueueRecord,
    UnflacInput,
)
from arr_post_processor.state import Job, StateStore
from prometheus_client.parser import text_string_to_metric_families
from pydantic import TypeAdapter

INSPECTIONS = TypeAdapter(list[UnflacInput])
IMPORT_CANDIDATES = TypeAdapter(list[ManualImportCandidate])
FIXTURES = Path(__file__).parent / "fixtures"


def queue_record(payload):
    return QueueRecord.model_validate(
        {
            "trackedDownloadStatus": "warning",
            "trackedDownloadState": "importPending",
            **payload,
        }
    )


def inspections(payload):
    return INSPECTIONS.validate_python(payload)


def import_candidates(payload):
    return IMPORT_CANDIDATES.validate_python(payload)


def metric_value(metrics, name, labels=None):
    expected_labels = labels or {}
    for family in text_string_to_metric_families(metrics):
        for sample in family.samples:
            if sample.name == name and sample.labels == expected_labels:
                return sample.value
    raise AssertionError(f"missing metric {name} with labels {expected_labels}")


class UnexpectedArchiveBackend:
    def members(self, archive):
        raise AssertionError(f"should not inspect archive: {archive}")

    def extract(self, archive, destination):
        raise AssertionError(f"should not extract {archive} into {destination}")


class LidarrPostProcessorTests(unittest.TestCase):
    def test_queue_record_normalizes_aiopyarr_protocol(self):
        record = queue_record({"protocol": ProtocolType.TORRENT})
        self.assertEqual(record.protocol, "torrent")

    def test_lidarr_service_only_handles_completed_import_warnings(self):
        eligible = queue_record(
            {
                "status": "completed",
                "protocol": "usenet",
                "downloadId": "download-1",
                "outputPath": "/downloads/album",
            }
        )
        healthy = eligible.model_copy(update={"tracked_download_status": "ok"})
        downloading = eligible.model_copy(update={"status": "downloading"})

        self.assertTrue(LidarrPostProcessorService.completed_record(eligible))
        self.assertFalse(LidarrPostProcessorService.completed_record(healthy))
        self.assertFalse(LidarrPostProcessorService.completed_record(downloading))

    def test_reads_lidarr_api_key(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "config.xml"
            config.write_text("<Config><ApiKey>secret-key</ApiKey></Config>", encoding="utf-8")
            self.assertEqual(read_api_key(config), "secret-key")

    def test_rejects_missing_api_key(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "config.xml"
            config.write_text("<Config />", encoding="utf-8")
            with self.assertRaises(PostProcessorError):
                read_api_key(config)

    def test_reads_hermes_api_key_credential(self):
        with tempfile.TemporaryDirectory() as directory:
            environment = Path(directory) / "api-server.env"
            environment.write_text("OTHER=value\nAPI_SERVER_KEY=secret-key\n", encoding="utf-8")

            self.assertEqual(read_environment_value(environment, "API_SERVER_KEY"), "secret-key")

    def test_rejects_ambiguous_hermes_api_key_credential(self):
        with tempfile.TemporaryDirectory() as directory:
            environment = Path(directory) / "api-server.env"
            environment.write_text(
                "API_SERVER_KEY=first\nAPI_SERVER_KEY=second\n", encoding="utf-8"
            )

            with self.assertRaises(PostProcessorError):
                read_environment_value(environment, "API_SERVER_KEY")

    def test_parses_named_radarr_source_roots(self):
        roots = parse_source_roots(
            ["torrents=/data/media/torrents/radarr", "usenet-manual=/data/media/usenet/manual"]
        )

        self.assertEqual([root.name for root in roots], ["torrents", "usenet-manual"])
        with self.assertRaises(ValueError):
            parse_source_roots(["torrents=relative/path"])

    def test_path_allowlist(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.assertTrue(is_within(root / "album" / "disc.cue", [root]))
            self.assertFalse(is_within(root.parent / "other" / "disc.cue", [root]))

    def test_native_tar_backend_extracts_regular_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = root / "album.tar"
            payload = b"audio"
            with tarfile.open(archive, mode="w") as output:
                member = tarfile.TarInfo("album/01.flac")
                member.size = len(payload)
                output.addfile(member, io.BytesIO(payload))

            backend = NativeArchiveBackend()
            members = backend.members(archive)
            self.assertEqual(
                members,
                [ArchiveMember("album/01.flac", len(payload), False, False)],
            )
            destination = root / "output"
            backend.extract(archive, destination)
            self.assertEqual((destination / "album" / "01.flac").read_bytes(), payload)

    def test_native_rar_backend_extracts_regular_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = root / "album.rar"
            archive.write_bytes(base64.b64decode((FIXTURES / "album.rar.b64").read_bytes()))

            backend = NativeArchiveBackend()
            members = backend.members(archive)
            self.assertEqual(
                [member.name for member in members],
                ["album.cue", "album.flac"],
            )
            destination = root / "output"
            backend.extract(archive, destination)
            self.assertIn('FILE "album.flac"', (destination / "album.cue").read_text())
            self.assertEqual((destination / "album.flac").read_text(), "fixture audio\n")

    def test_rar_extraction_timeout_is_a_source_failure(self):
        def timeout(*args, **kwargs):
            del args, kwargs
            raise subprocess.TimeoutExpired("unrar", 5)

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = root / "album.rar"
            archive.write_bytes(b"archive")
            backend = NativeArchiveBackend(timeout_seconds=5, run=timeout)

            with self.assertRaisesRegex(SourceInvalid, "extraction timed out"):
                backend.extract(archive, root / "output")

    def test_archive_transform_rejects_unsafe_member_before_extraction(self):
        class FakeBackend:
            extracted = False

            def members(self, archive):
                del archive
                return [ArchiveMember("../escape.flac", 5, False, False)]

            def extract(self, archive, destination):
                del archive, destination
                self.extracted = True

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source"
            source.mkdir()
            (source / "album.tar").write_bytes(b"archive")
            backend = FakeBackend()
            transform = ArchiveTransform(backend)
            with self.assertRaises(SourceInvalid):
                transform.apply(source, root / "output")
            self.assertFalse(backend.extracted)

    def test_archive_then_already_split_cue_pipeline(self):
        class FakeBackend:
            def members(self, archive):
                del archive
                return [
                    ArchiveMember("album/album.cue", 100, False, False),
                    ArchiveMember("album/01.flac", 100, False, False),
                    ArchiveMember("album/02.flac", 100, False, False),
                ]

            def extract(self, archive, destination):
                del archive
                album = destination / "album"
                album.mkdir()
                (album / "album.cue").write_text(
                    "\n".join(
                        [
                            'FILE "01.flac" WAVE',
                            "  TRACK 01 AUDIO",
                            'FILE "02.flac" WAVE',
                            "  TRACK 02 AUDIO",
                        ]
                    ),
                    encoding="utf-8",
                )
                (album / "01.flac").write_bytes(b"first")
                (album / "02.flac").write_bytes(b"second")

        class UnexpectedRunner:
            def inspect(self, cue):
                raise AssertionError(f"should not inspect an already split CUE: {cue}")

            def split(self, cue, output_dir):
                raise AssertionError(f"should not split {cue} into {output_dir}")

            def verify_flac(self, path):
                raise AssertionError(f"should not verify {path}")

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "downloads" / "album"
            source.mkdir(parents=True)
            (source / "album.tar").write_bytes(b"archive")
            work = root / "work"
            pipeline = LidarrPipeline(
                transforms=[
                    ArchiveTransform(FakeBackend()),
                    CueTransform(UnexpectedRunner(), [root / "downloads", work]),
                ],
                allowed_roots=[root / "downloads"],
                work_root=work,
            )

            result = pipeline.execute(source, "download-1")

            self.assertEqual(result.transforms, ("archive_extract",))
            self.assertEqual([path.name for path in result.audio_files], ["01.flac", "02.flac"])
            self.assertTrue(all(path.is_relative_to(source) for path in result.audio_files))
            self.assertTrue(all("_arr-post-processor" in path.parts for path in result.audio_files))
            self.assertTrue(all(not path.is_relative_to(work) for path in result.audio_files))
            self.assertTrue((source / "album.tar").exists())

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

    def test_source_local_staging_is_excluded_from_discovery(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "album"
            source.mkdir()
            archive = source / "album.tar"
            archive.write_bytes(b"archive")
            transform = ArchiveTransform(UnexpectedArchiveBackend())
            original_fingerprint = output_fingerprint(
                source,
                suffixes=frozenset({".tar", ".flac"}),
            )
            staging = source / "_arr-post-processor" / "job" / "01-archive_extract"
            staging.mkdir(parents=True)
            (staging / "01.flac").write_bytes(b"staged")

            self.assertTrue(transform.applies(source))
            self.assertEqual(
                output_fingerprint(
                    source,
                    suffixes=frozenset({".tar", ".flac"}),
                ),
                original_fingerprint,
            )

    def test_unflac_inspection(self):
        payload = [
            {
                "path": "album.cue",
                "audio": [{"path": "/music/album.ape", "tracks": [{}, {}]}],
            }
        ]

        def run(*args, **kwargs):
            return subprocess.CompletedProcess(args[0], 0, json.dumps(payload), "")

        self.assertEqual(UnflacRunner(run).inspect(Path("album.cue")), inspections(payload))

    def test_unflac_inspection_failure(self):
        def run(*args, **kwargs):
            return subprocess.CompletedProcess(args[0], 1, "", "bad cue")

        with self.assertRaises(SourceInvalid):
            UnflacRunner(run).inspect(Path("album.cue"))

    def test_native_lidarr_client_round_trip(self):
        requests: list[tuple[str, str, str | None, object]] = []

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, format, *args):
                del format, args

            def send_json(self, payload):
                body = json.dumps(payload).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self):
                requests.append(("GET", self.path, self.headers.get("X-Api-Key"), None))
                path = urllib.parse.urlparse(self.path).path
                if path == "/api/v1/queue":
                    self.send_json({"records": []})
                elif path == "/api/v1/manualimport":
                    self.send_json([])
                elif path == "/api/v1/command/12":
                    self.send_json({"id": 12, "status": "completed"})
                else:
                    self.send_error(404)

            def do_POST(self):
                length = int(self.headers["Content-Length"])
                payload = json.loads(self.rfile.read(length))
                requests.append(("POST", self.path, self.headers.get("X-Api-Key"), payload))
                self.send_json({"id": 12})

            def do_DELETE(self):
                requests.append(("DELETE", self.path, self.headers.get("X-Api-Key"), None))
                self.send_response(200)
                self.end_headers()

        @contextmanager
        def server() -> Iterator[str]:
            httpd = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
            thread = Thread(target=httpd.serve_forever)
            thread.start()
            try:
                host, port = httpd.server_address
                yield f"http://{host}:{port}"
            finally:
                httpd.shutdown()
                thread.join()
                httpd.server_close()

        with server() as base_url:
            client = LidarrClient(base_url, "secret")
            self.assertEqual(client.queue(), [])
            self.assertEqual(
                client.manual_import(
                    Path("/staging/album"),
                    queue_record({"downloadId": "download-1", "artistId": 7}),
                ),
                [],
            )
            self.assertEqual(
                client.submit_manual_import(
                    [
                        ManualImportFile(
                            path=Path("/staging/album/01.flac"),
                            artist_id=7,
                            album_id=8,
                            album_release_id=9,
                            track_ids=[10],
                            quality={},
                            download_id="download-1",
                            disable_release_switching=False,
                        )
                    ]
                ),
                12,
            )
            self.assertEqual(client.command(12).status, "completed")
            client.detach_queue_item(42, blocklist=True)

        self.assertTrue(all(api_key == "secret" for _, _, api_key, _ in requests))

        queue_query = urllib.parse.parse_qs(urllib.parse.urlparse(requests[0][1]).query)
        self.assertEqual(queue_query["pageSize"], ["2000"])
        self.assertEqual(queue_query["includeUnknownArtistItems"], ["True"])

        import_query = urllib.parse.parse_qs(urllib.parse.urlparse(requests[1][1]).query)
        self.assertEqual(import_query["folder"], ["/staging/album"])
        self.assertEqual(import_query["downloadId"], ["download-1"])
        self.assertEqual(import_query["artistId"], ["7"])
        self.assertEqual(import_query["replaceExistingFiles"], ["True"])
        self.assertEqual(import_query["filterExistingFiles"], ["False"])

        self.assertEqual(requests[2][0:2], ("POST", "/api/v1/command"))
        self.assertEqual(
            requests[2][3],
            {
                "name": "ManualImport",
                "files": [
                    {
                        "path": "/staging/album/01.flac",
                        "artistId": 7,
                        "albumId": 8,
                        "albumReleaseId": 9,
                        "trackIds": [10],
                        "quality": {},
                        "indexerFlags": 0,
                        "downloadId": "download-1",
                        "disableReleaseSwitching": False,
                    }
                ],
                "importMode": "auto",
                "replaceExistingFiles": True,
            },
        )

        parsed = urllib.parse.urlparse(requests[4][1])
        delete_query = urllib.parse.parse_qs(parsed.query)
        self.assertEqual(requests[4][0], "DELETE")
        self.assertEqual(parsed.path, "/api/v1/queue/42")
        self.assertEqual(delete_query["removeFromClient"], ["False"])
        self.assertEqual(delete_query["blocklist"], ["True"])
        self.assertEqual(delete_query["skipReDownload"], ["True"])

    def test_image_style_inspection_is_eligible(self):
        cue = Path("/music/album.cue")
        payload = [{"audio": [{"path": "/music/album.flac", "tracks": [{}, {}, {}]}]}]
        summary = inspection_summary(cue, inspections(payload))
        self.assertTrue(summary.eligible)
        self.assertEqual(summary.track_count, 3)

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
        self.assertFalse(inspection_summary(cue, inspections(payload)).eligible)

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
            import_candidates(outputs),
            generated,
            queue_record({"artistId": 4, "albumId": 5, "downloadId": "abc"}),
        )
        self.assertEqual([item.track_ids for item in files], [[10], [11]])
        self.assertTrue(all(item.download_id == "abc" for item in files))

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
            build_manual_import_files(
                import_candidates(outputs),
                generated,
                queue_record({"artistId": 4, "albumId": 5}),
            )

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
                import_candidates([output]),
                [Path("/stage/01.flac")],
                queue_record({"artistId": 4, "albumId": 5}),
            )

    def test_metrics_include_health_state_and_totals(self):
        with tempfile.TemporaryDirectory() as directory:
            store = StateStore(Path(directory) / "state.json")
            store.state.jobs["abc"] = Job(status="awaiting_manual_match")
            store.state.totals.success = 3
            store.state.totals.failed = 1
            store.state.totals.ignored = 2
            store.state.totals.manual = 1
            store.state.totals.tracks = 24
            metrics = render_metrics(store.state, ok=True, now=1234.0)
            self.assertEqual(
                metric_value(metrics, "host_observability_lidarr_post_processor_ok"),
                1,
            )
            self.assertEqual(
                metric_value(
                    metrics,
                    "host_observability_lidarr_post_processor_jobs",
                    {"state": "awaiting_manual_match"},
                ),
                1,
            )
            self.assertEqual(
                metric_value(
                    metrics,
                    "host_observability_lidarr_post_processor_jobs_total",
                    {"result": "success"},
                ),
                3,
            )
            self.assertEqual(
                metric_value(metrics, "host_observability_lidarr_post_processor_tracks_total"),
                24,
            )

    def test_state_round_trip_is_typed_and_rejects_invalid_data(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "state.json"
            store = StateStore(path)
            store.state.jobs["abc"] = Job(
                download_id="abc",
                status="matching",
                ready_root=Path("/staging/abc"),
                attempts=2,
            )
            store.save()

            loaded = StateStore(path).state.jobs["abc"]
            self.assertEqual(loaded.ready_root, Path("/staging/abc"))
            self.assertEqual(loaded.attempts, 2)

            path.write_text(
                json.dumps({"jobs": {"abc": {"attempts": "invalid"}}}),
                encoding="utf-8",
            )
            with self.assertRaises(PostProcessorError):
                StateStore(path)

    def test_completed_download_is_split_imported_and_cleaned(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            download = root / "torrents" / "album"
            download.mkdir(parents=True)
            cue = download / "album.cue"
            audio = download / "album.ape"
            cue.write_text('FILE "album.ape" WAVE\n', encoding="utf-8")
            audio.write_bytes(b"ape")
            record = queue_record(
                {
                    "status": "completed",
                    "protocol": "torrent",
                    "downloadId": "abc",
                    "outputPath": str(download),
                    "title": "Album",
                    "artistId": 4,
                    "albumId": 5,
                }
            )

            class FakeRunner:
                def inspect(self, cue_path):
                    return inspections(
                        [
                            {
                                "audio": [
                                    {
                                        "path": str(audio),
                                        "tracks": [{"number": 1}, {"number": 2}],
                                    }
                                ]
                            }
                        ]
                    )

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
                    if not folder.is_relative_to(download):
                        raise AssertionError("Lidarr staging must remain below its download")
                    return import_candidates(
                        [
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
                            for index, path in enumerate(sorted(folder.rglob("*.flac")), start=10)
                        ]
                    )

                def submit_manual_import(self, files):
                    self.submitted = files
                    return 7

                def command(self, command_id):
                    return CommandStatus(id=command_id, status="completed")

            client = FakeClient()
            store = StateStore(root / "state.json")
            now = [1000.0]
            service = LidarrPostProcessorService(
                client_factory=lambda: client,
                runner=FakeRunner(),
                archive_backend=UnexpectedArchiveBackend(),
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
            self.assertEqual(store.state.jobs["abc"].status, "awaiting_queue_removal")
            self.assertEqual(len(client.submitted), 2)
            client.records = []
            now[0] += 1
            service.iteration()
            self.assertEqual(store.state.jobs["abc"].status, "complete")
            self.assertEqual(store.state.totals.success, 1)
            self.assertEqual(store.state.totals.tracks, 2)
            self.assertFalse((download / "_lidarr-cue-split").exists())
            self.assertFalse((download / "_arr-post-processor").exists())
            self.assertTrue(audio.exists())

    def test_non_cue_download_recovers_from_needs_attention(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            download = root / "usenet" / "manual" / "album"
            download.mkdir(parents=True)
            (download / "cover.jpg").write_bytes(b"jpeg")
            record = queue_record(
                {
                    "status": "completed",
                    "protocol": "usenet",
                    "downloadId": "abc",
                    "outputPath": str(download),
                }
            )

            class FakeClient:
                def queue(self):
                    return [record]

            store = StateStore(root / "state.json")
            store.state.jobs["abc"] = Job(
                download_id="abc",
                status="needs_attention",
                error="download path is outside allowed roots",
                updated_at=1000.0,
            )
            service = LidarrPostProcessorService(
                client_factory=FakeClient,
                runner=object(),
                archive_backend=UnexpectedArchiveBackend(),
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
            self.assertEqual(store.state.jobs["abc"].status, "ignored")
            self.assertEqual(store.state.jobs["abc"].error, "")
            self.assertEqual(store.state.totals.ignored, 1)
            service.iteration()
            self.assertEqual(store.state.totals.ignored, 1)

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
            record = queue_record(
                {
                    "status": "completed",
                    "protocol": "torrent",
                    "downloadId": "abc",
                    "outputPath": str(download),
                }
            )

            class FakeClient:
                def queue(self):
                    return [record]

            class UnexpectedRunner:
                def inspect(self, cue):
                    raise AssertionError(f"unflac should not inspect {cue}")

            store = StateStore(root / "state.json")
            store.state.jobs["abc"] = Job(
                download_id="abc",
                status="needs_attention",
                attempts=3,
                error="unflac could not parse EAC cue",
                updated_at=1000.0,
            )
            service = LidarrPostProcessorService(
                client_factory=FakeClient,
                runner=UnexpectedRunner(),
                archive_backend=UnexpectedArchiveBackend(),
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
            self.assertEqual(store.state.jobs["abc"].status, "ignored")
            self.assertEqual(store.state.jobs["abc"].error, "")
            self.assertEqual(store.state.totals.ignored, 1)
            service.iteration()
            self.assertEqual(store.state.totals.ignored, 1)

    def test_manual_match_preserves_generated_tracks_without_retrying_split(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            download = root / "torrents" / "album"
            download.mkdir(parents=True)
            cue = download / "album.cue"
            audio = download / "album.ape"
            cue.write_text('FILE "album.ape" WAVE\n', encoding="utf-8")
            audio.write_bytes(b"ape")
            record = queue_record(
                {
                    "id": 42,
                    "status": "completed",
                    "protocol": "torrent",
                    "downloadId": "abc",
                    "outputPath": str(download),
                    "title": "Album",
                    "artistId": 4,
                    "albumId": 5,
                }
            )

            class FakeRunner:
                def __init__(self):
                    self.splits = 0

                def inspect(self, cue_path):
                    return inspections(
                        [
                            {
                                "audio": [
                                    {
                                        "path": str(audio),
                                        "tracks": [{"number": 1}, {"number": 2}],
                                    }
                                ]
                            }
                        ]
                    )

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
                    return import_candidates(
                        [
                            {
                                "path": str(path),
                                "artist": {"id": 4},
                                "album": {"id": 5},
                                "tracks": [{"id": index}],
                                "rejections": [{"reason": "album match is too weak"}],
                            }
                            for index, path in enumerate(sorted(folder.rglob("*.flac")), start=10)
                        ]
                    )

                def detach_queue_item(self, queue_id, *, blocklist):
                    self.detached.append((queue_id, blocklist))

            client = FakeClient()
            runner = FakeRunner()
            store = StateStore(root / "state.json")
            now = [1000.0]
            service = LidarrPostProcessorService(
                client_factory=lambda: client,
                runner=runner,
                archive_backend=UnexpectedArchiveBackend(),
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
            job = store.state.jobs["abc"]
            self.assertIsNotNone(job.ready_root)
            ready_root = job.ready_root
            assert ready_root is not None
            self.assertEqual(job.status, "awaiting_manual_match")
            self.assertEqual(len(list(ready_root.rglob("*.flac"))), 2)
            self.assertEqual(store.state.totals.manual, 1)
            self.assertEqual(client.detached, [])
            self.assertTrue(audio.exists())

            service.iteration()
            self.assertEqual(runner.splits, 1)
            client.records = []
            for _ in range(3):
                now[0] += 30
                service.iteration()
            self.assertEqual(job.status, "manual_resolved")
            self.assertFalse(ready_root.exists())

    def test_manual_match_staging_expires_while_queue_item_remains(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            work = root / "work"
            ready_root = work / safe_component("abc") / "01-cue_split"
            ready_root.mkdir(parents=True)
            (ready_root / "01.flac").write_bytes(b"flac")
            orphan = work / "orphan.partial"
            orphan.mkdir()
            os.utime(orphan, (900.0, 900.0))
            record = queue_record(
                {
                    "status": "completed",
                    "protocol": "usenet",
                    "downloadId": "abc",
                    "outputPath": str(root / "downloads"),
                }
            )

            class FakeClient:
                def queue(self):
                    return [record]

            store = StateStore(root / "state.json")
            job = Job(
                download_id="abc",
                status="awaiting_manual_match",
                ready_root=ready_root,
                updated_at=1000.0,
            )
            store.state.jobs["abc"] = job
            service = LidarrPostProcessorService(
                client_factory=FakeClient,
                runner=object(),
                archive_backend=UnexpectedArchiveBackend(),
                store=store,
                allowed_roots=[root / "downloads"],
                work_root=work,
                metrics_file=root / "metrics.prom",
                settle_seconds=0,
                command_timeout_seconds=60,
                attention_staging_retention_seconds=60,
                now=lambda: 1061.0,
                sleep=lambda _: None,
            )

            service.iteration()

            self.assertFalse(ready_root.exists())
            self.assertFalse(orphan.exists())
            self.assertIsNone(job.ready_root)
            self.assertEqual(job.resolution, "attention_staging_expired")

    def test_external_archive_staging_is_cleaned_and_retried_after_upgrade(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "downloads" / "album"
            source.mkdir(parents=True)
            (source / "album.tar").write_bytes(b"archive")
            work = root / "work"
            external_job_root = work / safe_component("abc")
            ready_root = external_job_root / "01-archive_extract"
            ready_root.mkdir(parents=True)
            (ready_root / "01.flac").write_bytes(b"flac")
            record = queue_record(
                {
                    "status": "completed",
                    "protocol": "usenet",
                    "downloadId": "abc",
                    "outputPath": str(source),
                }
            )

            class FakeClient:
                def queue(self):
                    return [record]

            store = StateStore(root / "state.json")
            job = Job(
                download_id="abc",
                status="awaiting_manual_match",
                ready_root=ready_root,
                resolution="archive_extract",
                error="Lidarr returned no tracks",
                updated_at=1000.0,
            )
            store.state.jobs["abc"] = job
            service = LidarrPostProcessorService(
                client_factory=FakeClient,
                runner=object(),
                archive_backend=UnexpectedArchiveBackend(),
                store=store,
                allowed_roots=[root / "downloads"],
                work_root=work,
                metrics_file=root / "metrics.prom",
                settle_seconds=30,
                command_timeout_seconds=60,
                now=lambda: 1061.0,
                sleep=lambda _: None,
            )
            job.fingerprint = output_fingerprint(
                source,
                suffixes=service.pipeline.input_suffixes,
            )

            service.iteration()

            self.assertFalse(external_job_root.exists())
            self.assertEqual(job.status, "settling")
            self.assertIsNone(job.ready_root)
            self.assertIsNone(job.resolution)
            self.assertEqual(job.error, "")
            self.assertEqual(job.discovered_at, 1061.0)

    def test_transient_empty_queue_does_not_dismiss_problem_job(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            download = root / "torrents" / "album"
            download.mkdir(parents=True)
            record = queue_record(
                {
                    "id": 42,
                    "status": "completed",
                    "protocol": "torrent",
                    "downloadId": "abc",
                    "outputPath": str(download),
                }
            )

            class FakeClient:
                def __init__(self):
                    self.records = []

                def queue(self):
                    return self.records

            client = FakeClient()
            store = StateStore(root / "state.json")
            job = Job(
                download_id="abc",
                status="failed",
                attempts=1,
                error="temporary source failure",
                updated_at=1000.0,
            )
            store.state.jobs["abc"] = job
            now = [1001.0]
            service = LidarrPostProcessorService(
                client_factory=lambda: client,
                runner=object(),
                archive_backend=UnexpectedArchiveBackend(),
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
            self.assertEqual(job.status, "failed")
            self.assertEqual(job.missing_queue_observations, 1)
            client.records = [record]
            service.iteration()
            self.assertEqual(job.status, "failed")
            self.assertEqual(job.missing_queue_observations, 0)

    def test_legacy_post_split_failure_becomes_manual_work(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            download = root / "torrents" / "album"
            ready_root = download / "_lidarr-cue-split" / "abc"
            ready_root.mkdir(parents=True)
            generated = ready_root / "01.flac"
            generated.write_bytes(b"flac")
            record = queue_record(
                {
                    "status": "completed",
                    "protocol": "torrent",
                    "downloadId": "abc",
                    "outputPath": str(download),
                }
            )

            class FakeClient:
                def queue(self):
                    return [record]

            store = StateStore(root / "state.json")
            job = Job(
                download_id="abc",
                status="needs_attention",
                ready_root=ready_root,
                error="Lidarr rejected the generated track",
                updated_at=1000.0,
            )
            store.state.jobs["abc"] = job
            service = LidarrPostProcessorService(
                client_factory=FakeClient,
                runner=object(),
                archive_backend=UnexpectedArchiveBackend(),
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
            self.assertEqual(job.status, "awaiting_manual_match")
            self.assertTrue(generated.exists())
            self.assertEqual(store.state.totals.manual, 1)

    def test_problem_job_is_dismissed_and_expires_after_leaving_queue(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)

            class FakeClient:
                def queue(self):
                    return []

            store = StateStore(root / "state.json")
            store.state.jobs["abc"] = Job(
                download_id="abc",
                status="needs_attention",
                error="malformed cue",
                updated_at=1000.0,
            )
            now = [1001.0]
            service = LidarrPostProcessorService(
                client_factory=FakeClient,
                runner=object(),
                archive_backend=UnexpectedArchiveBackend(),
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
            self.assertEqual(store.state.jobs["abc"].status, "dismissed")
            self.assertEqual(store.state.jobs["abc"].error, "malformed cue")
            metrics = render_metrics(store.state, ok=True, now=now[0])
            self.assertEqual(
                metric_value(
                    metrics,
                    "host_observability_lidarr_post_processor_jobs",
                    {"state": "dismissed"},
                ),
                1,
            )
            self.assertEqual(
                metric_value(
                    metrics,
                    "host_observability_lidarr_post_processor_jobs",
                    {"state": "needs_attention"},
                ),
                0,
            )

            now[0] += 7 * 86400
            service.iteration()
            self.assertNotIn("abc", store.state.jobs)

    def test_exhausted_invalid_source_is_detached_but_files_are_retained(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            download = root / "torrents" / "album"
            download.mkdir(parents=True)
            cue = download / "album.cue"
            cue.write_text("malformed cue", encoding="utf-8")
            record = queue_record(
                {
                    "id": 42,
                    "status": "completed",
                    "protocol": "torrent",
                    "downloadId": "abc",
                    "outputPath": str(download),
                }
            )

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
            service = LidarrPostProcessorService(
                client_factory=lambda: client,
                runner=runner,
                archive_backend=UnexpectedArchiveBackend(),
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
            self.assertEqual(store.state.jobs["abc"].attempts, 1)
            service.iteration()
            self.assertEqual(runner.inspections, 1)

            for attempt in (2, 3):
                now[0] += 300
                service.iteration()
                self.assertEqual(store.state.jobs["abc"].attempts, attempt)

            now[0] += 300
            service.iteration()
            self.assertEqual(runner.inspections, 3)
            self.assertEqual(store.state.jobs["abc"].status, "source_invalid")
            self.assertEqual(store.state.totals.failed, 3)
            self.assertEqual(store.state.totals.source_invalid, 1)
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
            record = queue_record(
                {
                    "id": 42,
                    "status": "completed",
                    "protocol": "torrent",
                    "downloadId": "abc",
                    "outputPath": str(download),
                }
            )

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
            job = Job(
                download_id="abc",
                status="failed",
                attempts=3,
                failure_kind="source_invalid",
                failure_fingerprint=failed_fingerprint,
                updated_at=1000.0,
            )
            store.state.jobs["abc"] = job
            service = LidarrPostProcessorService(
                client_factory=lambda: client,
                runner=FailingRunner(),
                archive_backend=UnexpectedArchiveBackend(),
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
            self.assertEqual(job.status, "failed")
            self.assertEqual(job.attempts, 1)
            self.assertEqual(client.detached, [])

    def test_unavailable_source_is_detached_without_blocklisting(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            missing_download = root / "torrents" / "missing"
            record = queue_record(
                {
                    "id": 42,
                    "status": "completed",
                    "protocol": "torrent",
                    "downloadId": "abc",
                    "outputPath": str(missing_download),
                }
            )

            class FakeClient:
                def __init__(self):
                    self.detached = []

                def queue(self):
                    return [record]

                def detach_queue_item(self, queue_id, *, blocklist):
                    self.detached.append((queue_id, blocklist))

            client = FakeClient()
            store = StateStore(root / "state.json")
            job = Job(
                download_id="abc",
                status="failed",
                attempts=3,
                failure_kind="source_unavailable",
                error="download path does not exist",
                updated_at=1000.0,
            )
            store.state.jobs["abc"] = job
            service = LidarrPostProcessorService(
                client_factory=lambda: client,
                runner=object(),
                archive_backend=UnexpectedArchiveBackend(),
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
            self.assertEqual(job.status, "source_unavailable")
            self.assertEqual(client.detached, [(42, False)])


if __name__ == "__main__":
    unittest.main()
