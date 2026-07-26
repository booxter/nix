#!/usr/bin/env python3

import argparse
import fcntl
import hashlib
import json
import logging
import os
import stat
import subprocess
import sys
import uuid
import zipfile
from contextlib import contextmanager
from pathlib import Path
from typing import Iterator


LOG = logging.getLogger("ebook-converter")
SUPPORTED_SOURCE_SUFFIXES = {".azw3", ".mobi"}


class EbookConverterError(RuntimeError):
    pass


class ConversionBusy(EbookConverterError):
    pass


class CalibreRunner:
    def __init__(self, executable: str = "ebook-convert"):
        self.executable = executable

    def convert(self, source: Path, destination: Path) -> None:
        try:
            subprocess.run(
                [self.executable, str(source), str(destination)],
                check=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
            )
        except subprocess.CalledProcessError as exc:
            output = exc.stdout.strip() if exc.stdout else "no converter output"
            raise EbookConverterError(
                f"Calibre conversion failed for {source.name}: {output[-1000:]}"
            ) from exc


def is_within(path: Path, root: Path) -> bool:
    try:
        path.relative_to(root)
    except ValueError:
        return False
    return True


def validate_epub(path: Path) -> None:
    if not path.is_file() or path.stat().st_size == 0:
        raise EbookConverterError(f"converter produced an empty EPUB: {path}")

    try:
        with zipfile.ZipFile(path) as archive:
            if archive.testzip() is not None:
                raise EbookConverterError(f"converter produced a corrupt EPUB: {path}")
            names = set(archive.namelist())
            if "mimetype" not in names:
                raise EbookConverterError(f"EPUB has no mimetype entry: {path}")
            if archive.read("mimetype") != b"application/epub+zip":
                raise EbookConverterError(f"EPUB has an invalid mimetype: {path}")
            if "META-INF/container.xml" not in names:
                raise EbookConverterError(f"EPUB has no container metadata: {path}")
    except zipfile.BadZipFile as exc:
        raise EbookConverterError(f"converter produced an invalid EPUB: {path}") from exc


def safe_source_path(source: Path, library_root: Path) -> Path:
    if source.is_symlink():
        raise EbookConverterError(f"refusing to convert symlink: {source}")
    try:
        resolved = source.resolve(strict=True)
    except FileNotFoundError as exc:
        raise EbookConverterError(f"source does not exist: {source}") from exc
    if not is_within(resolved, library_root):
        raise EbookConverterError(
            f"source is outside the configured library root: {resolved}"
        )
    if not resolved.is_file():
        raise EbookConverterError(f"source is not a regular file: {resolved}")
    if resolved.suffix.lower() not in SUPPORTED_SOURCE_SUFFIXES:
        raise EbookConverterError(f"unsupported source format: {resolved}")
    return resolved


@contextmanager
def source_lock(source: Path, lock_root: Path) -> Iterator[None]:
    lock_root.mkdir(parents=True, exist_ok=True)
    lock_name = hashlib.sha256(os.fsencode(source)).hexdigest() + ".lock"
    lock_path = lock_root / lock_name
    fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o660)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise ConversionBusy(f"conversion is already active for {source}") from exc
        yield
    finally:
        os.close(fd)


def hidden_source_path(source: Path) -> Path:
    return source.with_name(
        f".{source.stem}.ebook-converter-source{source.suffix.lower()}"
    )


def convert_path(
    source: Path,
    *,
    library_root: Path,
    lock_root: Path,
    runner: CalibreRunner,
) -> Path:
    library_root = library_root.resolve(strict=True)
    source = safe_source_path(source, library_root)
    destination = source.with_suffix(".epub")

    with source_lock(source, lock_root):
        if destination.exists():
            raise EbookConverterError(
                f"refusing to replace existing EPUB beside source: {destination}"
            )

        hidden_source = hidden_source_path(source)
        if hidden_source.exists():
            raise EbookConverterError(
                f"stale hidden conversion source requires attention: {hidden_source}"
            )

        temporary_epub = source.with_name(
            f".{source.stem}.{uuid.uuid4().hex}.ebook-converter-partial.epub"
        )
        source_mode = stat.S_IMODE(source.stat().st_mode)
        os.replace(source, hidden_source)
        try:
            runner.convert(hidden_source, temporary_epub)
            validate_epub(temporary_epub)
            os.chmod(temporary_epub, source_mode)
            with temporary_epub.open("rb") as output_file:
                os.fsync(output_file.fileno())
            os.replace(temporary_epub, destination)
            hidden_source.unlink()
        except Exception:
            temporary_epub.unlink(missing_ok=True)
            if hidden_source.exists() and not source.exists():
                os.replace(hidden_source, source)
            raise

    LOG.info("converted ebook: source=%s destination=%s", source, destination)
    return destination


def process_hook_payload(
    payload: object,
    *,
    library_root: Path,
    lock_root: Path,
    runner: CalibreRunner,
) -> list[Path]:
    if not isinstance(payload, dict) or payload.get("version") != 1:
        raise EbookConverterError("Shelfmark hook requires a version 1 JSON payload")
    if payload.get("phase") != "post_transfer":
        LOG.info("ignoring Shelfmark hook phase %r", payload.get("phase"))
        return []

    output = payload.get("output")
    if not isinstance(output, dict) or output.get("mode") != "folder":
        LOG.info("ignoring non-folder Shelfmark output")
        return []

    paths = payload.get("paths")
    final_paths = paths.get("final_paths") if isinstance(paths, dict) else None
    if not isinstance(final_paths, list) or not all(
        isinstance(path, str) for path in final_paths
    ):
        raise EbookConverterError("Shelfmark hook payload has invalid final paths")

    converted = []
    for path_string in final_paths:
        path = Path(path_string)
        if path.suffix.lower() not in SUPPORTED_SOURCE_SUFFIXES:
            continue
        converted.append(
            convert_path(
                path,
                library_root=library_root,
                lock_root=lock_root,
                runner=runner,
            )
        )
    return converted


def hook_command(args: argparse.Namespace) -> int:
    try:
        payload = json.load(sys.stdin)
        converted = process_hook_payload(
            payload,
            library_root=Path(args.library_root),
            lock_root=Path(args.lock_root),
            runner=CalibreRunner(),
        )
    except (EbookConverterError, json.JSONDecodeError, OSError) as exc:
        LOG.error("Shelfmark ebook conversion hook failed: %s", exc)
        return 1

    LOG.info("Shelfmark ebook conversion hook complete: converted=%d", len(converted))
    return 0


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Convert library MOBI/AZW3 files to EPUB without modifying torrent data"
    )
    parser.add_argument(
        "--log-level",
        default="INFO",
        choices=["DEBUG", "INFO", "WARNING", "ERROR"],
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    hook_parser = subparsers.add_parser(
        "hook", help="process a Shelfmark post-transfer JSON payload"
    )
    hook_parser.add_argument("--library-root", required=True)
    hook_parser.add_argument("--lock-root", required=True)
    hook_parser.add_argument("target", help="target path supplied by Shelfmark")
    hook_parser.set_defaults(handler=hook_command)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv if argv is not None else sys.argv[1:])
    logging.basicConfig(
        level=getattr(logging, args.log_level),
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    return args.handler(args)


if __name__ == "__main__":
    raise SystemExit(main())
