import json
import os
import tempfile
import unittest
import zipfile
from pathlib import Path

from srvarr_ebook_converter.app import (
    EbookConverterService,
    EbookConverterError,
    StateStore,
    convert_path,
    discover_sources,
    prometheus_metrics,
    process_hook_payload,
    recover_stale_sources,
    validate_epub,
)


class FakeRunner:
    def __init__(self, *, fail: bool = False):
        self.fail = fail
        self.calls: list[tuple[Path, Path]] = []

    def convert(self, source: Path, destination: Path) -> None:
        self.calls.append((source, destination))
        if self.fail:
            raise EbookConverterError("injected conversion failure")
        write_epub(destination)


def write_epub(path: Path) -> None:
    with zipfile.ZipFile(path, "w") as archive:
        archive.writestr(
            "mimetype",
            "application/epub+zip",
            compress_type=zipfile.ZIP_STORED,
        )
        archive.writestr("META-INF/container.xml", "<container/>")
        archive.writestr("book.xhtml", "<html><body>book</body></html>")


class ConvertPathTests(unittest.TestCase):
    def test_converts_library_hardlink_without_changing_torrent_source(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            root = Path(tmp_dir)
            library = root / "library"
            torrents = root / "torrents"
            locks = root / "locks"
            library.mkdir()
            torrents.mkdir()
            torrent_source = torrents / "book.mobi"
            torrent_source.write_bytes(b"original torrent payload")
            library_source = library / "book.mobi"
            os.link(torrent_source, library_source)
            source_inode = torrent_source.stat().st_ino
            runner = FakeRunner()

            destination = convert_path(
                library_source,
                library_root=library,
                lock_root=locks,
                runner=runner,
            )

            self.assertEqual(destination, (library / "book.epub").resolve())
            self.assertFalse(library_source.exists())
            self.assertEqual(torrent_source.read_bytes(), b"original torrent payload")
            self.assertEqual(torrent_source.stat().st_ino, source_inode)
            self.assertEqual(torrent_source.stat().st_nlink, 1)
            validate_epub(destination)
            self.assertEqual(runner.calls[0][0], library_source.resolve())

    def test_failed_conversion_restores_library_hardlink(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            root = Path(tmp_dir)
            library = root / "library"
            torrents = root / "torrents"
            library.mkdir()
            torrents.mkdir()
            torrent_source = torrents / "book.azw3"
            torrent_source.write_bytes(b"original torrent payload")
            library_source = library / "book.azw3"
            os.link(torrent_source, library_source)

            with self.assertRaisesRegex(EbookConverterError, "injected conversion failure"):
                convert_path(
                    library_source,
                    library_root=library,
                    lock_root=root / "locks",
                    runner=FakeRunner(fail=True),
                )

            self.assertTrue(library_source.exists())
            self.assertEqual(library_source.stat().st_ino, torrent_source.stat().st_ino)
            self.assertEqual(torrent_source.stat().st_nlink, 2)
            self.assertFalse((library / "book.epub").exists())

    def test_valid_existing_epub_is_kept_and_library_source_is_removed(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            root = Path(tmp_dir)
            library = root / "library"
            torrents = root / "torrents"
            library.mkdir()
            torrents.mkdir()
            torrent_source = torrents / "book.mobi"
            torrent_source.write_bytes(b"source")
            source = library / "book.mobi"
            os.link(torrent_source, source)
            destination = library / "book.epub"
            write_epub(destination)
            existing_epub = destination.read_bytes()
            runner = FakeRunner()

            result = convert_path(
                source,
                library_root=library,
                lock_root=root / "locks",
                runner=runner,
            )

            self.assertEqual(result, destination.resolve())
            self.assertFalse(source.exists())
            self.assertEqual(torrent_source.read_bytes(), b"source")
            self.assertEqual(torrent_source.stat().st_nlink, 1)
            self.assertEqual(destination.read_bytes(), existing_epub)
            self.assertEqual(runner.calls, [])

    def test_invalid_existing_epub_is_kept_with_source_for_attention(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            library = Path(tmp_dir) / "library"
            library.mkdir()
            source = library / "book.mobi"
            source.write_bytes(b"source")
            destination = library / "book.epub"
            destination.write_bytes(b"invalid")
            runner = FakeRunner()

            with self.assertRaisesRegex(EbookConverterError, "invalid EPUB"):
                convert_path(
                    source,
                    library_root=library,
                    lock_root=Path(tmp_dir) / "locks",
                    runner=runner,
                )

            self.assertEqual(source.read_bytes(), b"source")
            self.assertEqual(destination.read_bytes(), b"invalid")
            self.assertEqual(runner.calls, [])

    def test_source_outside_library_root_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            root = Path(tmp_dir)
            library = root / "library"
            library.mkdir()
            source = root / "outside.mobi"
            source.write_bytes(b"source")

            with self.assertRaisesRegex(EbookConverterError, "outside"):
                convert_path(
                    source,
                    library_root=library,
                    lock_root=root / "locks",
                    runner=FakeRunner(),
                )


class HookPayloadTests(unittest.TestCase):
    def test_converts_supported_final_paths_only(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            root = Path(tmp_dir)
            library = root / "library"
            library.mkdir()
            mobi = library / "book.mobi"
            cover = library / "cover.jpg"
            mobi.write_bytes(b"source")
            cover.write_bytes(b"cover")
            runner = FakeRunner()
            payload = self.payload([mobi, cover])

            converted = process_hook_payload(
                payload,
                library_root=library,
                lock_root=root / "locks",
                runner=runner,
            )

            self.assertEqual(converted, [(library / "book.epub").resolve()])
            self.assertTrue(cover.exists())
            self.assertEqual(len(runner.calls), 1)

    def test_non_folder_output_is_ignored(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            root = Path(tmp_dir)
            library = root / "library"
            library.mkdir()
            mobi = library / "book.mobi"
            mobi.write_bytes(b"source")
            runner = FakeRunner()
            payload = self.payload([mobi])
            payload["output"]["mode"] = "booklore"

            converted = process_hook_payload(
                payload,
                library_root=library,
                lock_root=root / "locks",
                runner=runner,
            )

            self.assertEqual(converted, [])
            self.assertTrue(mobi.exists())
            self.assertEqual(runner.calls, [])

    @staticmethod
    def payload(final_paths: list[Path]) -> dict:
        return json.loads(
            json.dumps(
                {
                    "version": 1,
                    "phase": "post_transfer",
                    "output": {"mode": "folder"},
                    "paths": {
                        "final_paths": [str(path) for path in final_paths],
                    },
                }
            )
        )


class MutableClock:
    def __init__(self, value: float):
        self.value = value

    def __call__(self) -> float:
        return self.value


class WatchServiceTests(unittest.TestCase):
    def test_stable_file_is_converted_on_second_iteration(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            root = Path(tmp_dir)
            library = root / "library"
            torrents = root / "torrents"
            library.mkdir()
            torrents.mkdir()
            torrent_source = torrents / "book.mobi"
            torrent_source.write_bytes(b"torrent payload")
            library_source = library / "book.mobi"
            os.link(torrent_source, library_source)
            store = StateStore(root / "state" / "state.json")
            runner = FakeRunner()
            clock = MutableClock(1000.0)
            service = EbookConverterService(
                library_root=library,
                lock_root=root / "locks",
                store=store,
                runner=runner,
                settle_seconds=30.0,
                max_attempts=3,
                now=clock,
            )

            service.iteration()
            self.assertEqual(runner.calls, [])
            self.assertEqual(
                store.data["files"][str(library_source.resolve())]["status"],
                "settling",
            )

            clock.value += 31.0
            service.iteration()

            job = store.data["files"][str(library_source.resolve())]
            self.assertEqual(job["status"], "complete")
            self.assertEqual(store.data["totals"]["success"], 1)
            self.assertFalse(library_source.exists())
            self.assertTrue((library / "book.epub").exists())
            self.assertEqual(torrent_source.read_bytes(), b"torrent payload")
            self.assertEqual(torrent_source.stat().st_nlink, 1)

    def test_old_attention_job_cleans_up_valid_existing_epub(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            root = Path(tmp_dir)
            library = root / "library"
            torrents = root / "torrents"
            library.mkdir()
            torrents.mkdir()
            torrent_source = torrents / "book.mobi"
            torrent_source.write_bytes(b"torrent payload")
            library_source = library / "book.mobi"
            os.link(torrent_source, library_source)
            destination = library / "book.epub"
            write_epub(destination)
            store = StateStore(root / "state.json")
            key = str(library_source.resolve())
            store.data["files"][key] = {
                "status": "needs_attention",
                "fingerprint": {
                    "device": library_source.stat().st_dev,
                    "inode": library_source.stat().st_ino,
                    "size": library_source.stat().st_size,
                    "mtime_ns": library_source.stat().st_mtime_ns,
                },
                "observed_at": 900.0,
                "updated_at": 900.0,
                "attempts": 3,
                "error": "refusing to replace existing EPUB",
            }
            runner = FakeRunner()
            clock = MutableClock(1000.0)
            service = EbookConverterService(
                library_root=library,
                lock_root=root / "locks",
                store=store,
                runner=runner,
                settle_seconds=30.0,
                max_attempts=3,
                now=clock,
            )

            service.iteration()
            self.assertEqual(store.data["files"][key]["status"], "settling")
            self.assertEqual(store.data["files"][key]["attempts"], 0)

            clock.value += 31.0
            service.iteration()

            job = store.data["files"][key]
            self.assertEqual(job["status"], "complete")
            self.assertEqual(job["destination"], str(destination.resolve()))
            self.assertFalse(library_source.exists())
            self.assertEqual(torrent_source.read_bytes(), b"torrent payload")
            self.assertEqual(torrent_source.stat().st_nlink, 1)
            self.assertEqual(runner.calls, [])

    def test_failed_file_stops_retrying_at_max_attempts(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            root = Path(tmp_dir)
            library = root / "library"
            library.mkdir()
            source = library / "book.mobi"
            source.write_bytes(b"source")
            store = StateStore(root / "state.json")
            runner = FakeRunner(fail=True)
            clock = MutableClock(1000.0)
            service = EbookConverterService(
                library_root=library,
                lock_root=root / "locks",
                store=store,
                runner=runner,
                settle_seconds=0.0,
                max_attempts=2,
                now=clock,
            )

            service.iteration()
            service.iteration()
            service.iteration()
            service.iteration()

            job = store.data["files"][str(source.resolve())]
            self.assertEqual(job["status"], "needs_attention")
            self.assertEqual(job["attempts"], 2)
            self.assertEqual(len(runner.calls), 2)
            self.assertTrue(source.exists())
            self.assertEqual(store.data["totals"]["failed"], 2)

    def test_stale_hidden_source_is_restored_after_interruption(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            root = Path(tmp_dir)
            library = root / "library"
            library.mkdir()
            source = library / "book.mobi"
            source.write_bytes(b"source")
            hidden = library / ".book.ebook-converter-source.mobi"
            os.replace(source, hidden)
            partial = library / ".book.deadbeef.ebook-converter-partial.epub"
            partial.write_bytes(b"partial")

            recovered = recover_stale_sources(library, root / "locks")

            self.assertEqual(recovered, 1)
            self.assertEqual(source.read_bytes(), b"source")
            self.assertFalse(hidden.exists())
            self.assertFalse(partial.exists())

    def test_stale_hidden_source_is_removed_after_publication(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            root = Path(tmp_dir)
            library = root / "library"
            library.mkdir()
            hidden = library / ".book.ebook-converter-source.azw3"
            hidden.write_bytes(b"source")
            destination = library / "book.epub"
            write_epub(destination)

            recovered = recover_stale_sources(library, root / "locks")

            self.assertEqual(recovered, 1)
            self.assertFalse(hidden.exists())
            validate_epub(destination)

    def test_discovery_ignores_hidden_conversion_files(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            library = Path(tmp_dir) / "library"
            library.mkdir()
            visible = library / "visible.mobi"
            visible.write_bytes(b"visible")
            (library / ".hidden.mobi").write_bytes(b"hidden")
            hidden_dir = library / ".work"
            hidden_dir.mkdir()
            (hidden_dir / "nested.azw3").write_bytes(b"hidden")

            self.assertEqual(discover_sources(library), [visible])

    def test_metrics_report_failed_and_attention_states(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            store = StateStore(Path(tmp_dir) / "state.json")
            store.data["files"] = {
                "one": {"status": "failed"},
                "two": {"status": "needs_attention"},
            }
            store.data["totals"] = {"success": 3, "failed": 2}

            metrics = prometheus_metrics(store, True, 1234.0)

            self.assertIn("host_observability_ebook_converter_ok 1", metrics)
            self.assertIn(
                'host_observability_ebook_converter_files{state="needs_attention"} 1',
                metrics,
            )
            self.assertIn(
                'host_observability_ebook_converter_files_total{result="success"} 3',
                metrics,
            )


if __name__ == "__main__":
    unittest.main()
