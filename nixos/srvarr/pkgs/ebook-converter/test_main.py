import json
import os
import tempfile
import unittest
import zipfile
from pathlib import Path

from main import (
    EbookConverterError,
    convert_path,
    process_hook_payload,
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
            self.assertTrue(runner.calls[0][0].name.startswith("."))
            self.assertEqual(runner.calls[0][0].suffix, ".mobi")

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

            with self.assertRaisesRegex(
                EbookConverterError, "injected conversion failure"
            ):
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

    def test_existing_epub_is_not_replaced_and_source_is_kept(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            library = Path(tmp_dir) / "library"
            library.mkdir()
            source = library / "book.mobi"
            source.write_bytes(b"source")
            destination = library / "book.epub"
            destination.write_bytes(b"existing")
            runner = FakeRunner()

            with self.assertRaisesRegex(EbookConverterError, "existing EPUB"):
                convert_path(
                    source,
                    library_root=library,
                    lock_root=Path(tmp_dir) / "locks",
                    runner=runner,
                )

            self.assertEqual(source.read_bytes(), b"source")
            self.assertEqual(destination.read_bytes(), b"existing")
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


if __name__ == "__main__":
    unittest.main()
