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
import time
import uuid
import zipfile
from collections import Counter
from contextlib import contextmanager
from pathlib import Path
from typing import Callable, Iterator


LOG = logging.getLogger("ebook-converter")
SUPPORTED_SOURCE_SUFFIXES = {".azw3", ".mobi"}
STATE_VERSION = 1
JOB_POLICY_VERSION = 2


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
        raise EbookConverterError(
            f"converter produced an invalid EPUB: {path}"
        ) from exc


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


def atomic_write_text(path: Path, contents: str, mode: int = 0o660) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{uuid.uuid4().hex}.tmp")
    try:
        with temporary.open("x", encoding="utf-8") as output:
            output.write(contents)
            output.flush()
            os.fsync(output.fileno())
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


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
            if destination.is_symlink():
                raise EbookConverterError(
                    f"refusing EPUB symlink beside source: {destination}"
                )
            validate_epub(destination)
            source.unlink()
            LOG.info(
                "removed redundant ebook source: source=%s destination=%s",
                source,
                destination,
            )
            return destination

        hidden_source = hidden_source_path(source)
        if hidden_source.exists():
            raise EbookConverterError(
                f"stale hidden conversion source requires attention: {hidden_source}"
            )

        temporary_epub = source.with_name(
            f".{source.stem}.{uuid.uuid4().hex}.ebook-converter-partial.epub"
        )
        source_mode = stat.S_IMODE(source.stat().st_mode)
        try:
            runner.convert(source, temporary_epub)
            validate_epub(temporary_epub)
            os.chmod(temporary_epub, source_mode)
            with temporary_epub.open("rb") as output_file:
                os.fsync(output_file.fileno())
            if destination.exists():
                raise EbookConverterError(
                    f"refusing to replace EPUB created during conversion: {destination}"
                )
            os.replace(temporary_epub, destination)
            source.unlink()
        except Exception:
            temporary_epub.unlink(missing_ok=True)
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


def source_fingerprint(path: Path) -> dict[str, int]:
    file_stat = path.stat()
    return {
        "device": file_stat.st_dev,
        "inode": file_stat.st_ino,
        "size": file_stat.st_size,
        "mtime_ns": file_stat.st_mtime_ns,
    }


def discover_sources(library_root: Path) -> list[Path]:
    candidates = []
    for path in library_root.rglob("*"):
        relative = path.relative_to(library_root)
        if any(part.startswith(".") for part in relative.parts):
            continue
        if (
            path.is_file()
            and not path.is_symlink()
            and path.suffix.lower() in SUPPORTED_SOURCE_SUFFIXES
        ):
            candidates.append(path)
    return sorted(candidates, key=lambda path: str(path).casefold())


def original_path_from_hidden(hidden: Path) -> Path | None:
    suffix = hidden.suffix.lower()
    if suffix not in SUPPORTED_SOURCE_SUFFIXES or not hidden.name.startswith("."):
        return None
    marker = f".ebook-converter-source{suffix}"
    visible_name = hidden.name[1:]
    if not visible_name.endswith(marker):
        return None
    original_stem = visible_name[: -len(marker)]
    if not original_stem:
        return None
    return hidden.with_name(original_stem + suffix)


def recover_stale_sources(library_root: Path, lock_root: Path) -> int:
    recovered = 0
    hidden_sources = sorted(
        (
            path
            for path in library_root.rglob(".*")
            if path.is_file() and original_path_from_hidden(path) is not None
        ),
        key=lambda path: str(path).casefold(),
    )
    for hidden in hidden_sources:
        original = original_path_from_hidden(hidden)
        if original is None:
            continue
        try:
            with source_lock(original, lock_root):
                destination = original.with_suffix(".epub")
                if destination.exists():
                    try:
                        validate_epub(destination)
                    except EbookConverterError:
                        if not original.exists():
                            os.replace(hidden, original)
                            LOG.error(
                                "restored source beside invalid published EPUB: %s",
                                original,
                            )
                            recovered += 1
                        continue
                    else:
                        hidden.unlink()
                        LOG.warning(
                            "cleaned stale conversion source after EPUB publication: %s",
                            hidden,
                        )
                        recovered += 1
                        continue
                if original.exists():
                    LOG.error(
                        "hidden conversion source conflicts with visible source: %s",
                        hidden,
                    )
                    continue
                for partial in original.parent.glob(
                    f".{original.stem}.*.ebook-converter-partial.epub"
                ):
                    partial.unlink(missing_ok=True)
                os.replace(hidden, original)
                LOG.warning("restored stale conversion source: %s", original)
                recovered += 1
        except ConversionBusy:
            continue
        except (EbookConverterError, OSError) as exc:
            LOG.error("failed to recover hidden conversion source %s: %s", hidden, exc)
    return recovered


class StateStore:
    def __init__(self, path: Path):
        self.path = path
        self.data = self.default_data()
        self.load()

    @staticmethod
    def default_data() -> dict:
        return {
            "version": STATE_VERSION,
            "files": {},
            "totals": {"success": 0, "failed": 0},
            "last_success": None,
        }

    def load(self) -> None:
        if not self.path.exists():
            return
        try:
            data = json.loads(self.path.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError) as exc:
            raise EbookConverterError(
                f"failed to read state file {self.path}: {exc}"
            ) from exc
        if not isinstance(data, dict) or data.get("version") != STATE_VERSION:
            raise EbookConverterError(f"unsupported state file format: {self.path}")
        if not isinstance(data.get("files"), dict) or not isinstance(
            data.get("totals"), dict
        ):
            raise EbookConverterError(f"invalid state file structure: {self.path}")
        self.data = data

    def save(self) -> None:
        atomic_write_text(
            self.path,
            json.dumps(self.data, indent=2, sort_keys=True) + "\n",
        )


def prometheus_metrics(store: StateStore, ok: bool, now: float) -> str:
    states = Counter(
        job.get("status", "unknown") for job in store.data["files"].values()
    )
    totals = store.data["totals"]
    lines = [
        "# HELP host_observability_ebook_converter_ok Whether the latest service iteration completed successfully.",
        "# TYPE host_observability_ebook_converter_ok gauge",
        f"host_observability_ebook_converter_ok {1 if ok else 0}",
        "# HELP host_observability_ebook_converter_last_run_timestamp_seconds Unix timestamp of the latest iteration.",
        "# TYPE host_observability_ebook_converter_last_run_timestamp_seconds gauge",
        f"host_observability_ebook_converter_last_run_timestamp_seconds {now}",
        "# HELP host_observability_ebook_converter_files Number of known files by state.",
        "# TYPE host_observability_ebook_converter_files gauge",
    ]
    for state_name in sorted(
        set(states)
        | {"complete", "converting", "failed", "needs_attention", "settling"}
    ):
        lines.append(
            f'host_observability_ebook_converter_files{{state="{state_name}"}} {states[state_name]}'
        )
    lines.extend(
        [
            "# HELP host_observability_ebook_converter_files_total Conversion attempts by result.",
            "# TYPE host_observability_ebook_converter_files_total counter",
            f'host_observability_ebook_converter_files_total{{result="success"}} {int(totals.get("success", 0))}',
            f'host_observability_ebook_converter_files_total{{result="failed"}} {int(totals.get("failed", 0))}',
        ]
    )
    if store.data.get("last_success") is not None:
        lines.extend(
            [
                "# HELP host_observability_ebook_converter_last_success_timestamp_seconds Unix timestamp of the latest successful conversion.",
                "# TYPE host_observability_ebook_converter_last_success_timestamp_seconds gauge",
                f"host_observability_ebook_converter_last_success_timestamp_seconds {float(store.data['last_success'])}",
            ]
        )
    return "\n".join(lines) + "\n"


class EbookConverterService:
    def __init__(
        self,
        *,
        library_root: Path,
        lock_root: Path,
        store: StateStore,
        runner: CalibreRunner,
        settle_seconds: float,
        max_attempts: int,
        now: Callable[[], float] = time.time,
    ):
        self.library_root = library_root.resolve(strict=True)
        self.lock_root = lock_root
        self.store = store
        self.runner = runner
        self.settle_seconds = settle_seconds
        self.max_attempts = max_attempts
        self.now = now

    def iteration(self) -> None:
        now = self.now()
        recover_stale_sources(self.library_root, self.lock_root)
        files = self.store.data["files"]

        for source in discover_sources(self.library_root):
            key = str(source.resolve())
            try:
                fingerprint = source_fingerprint(source)
            except FileNotFoundError:
                continue
            job = files.get(key)
            if (
                not isinstance(job, dict)
                or job.get("fingerprint") != fingerprint
                or job.get("policy_version") != JOB_POLICY_VERSION
            ):
                files[key] = {
                    "status": "settling",
                    "fingerprint": fingerprint,
                    "policy_version": JOB_POLICY_VERSION,
                    "observed_at": now,
                    "updated_at": now,
                    "attempts": 0,
                    "error": "",
                }
                continue
            if (
                job.get("status") == "needs_attention"
                and int(job.get("attempts", 0)) >= self.max_attempts
            ):
                continue
            if now - float(job.get("observed_at", now)) < self.settle_seconds:
                continue

            job.update(status="converting", updated_at=now, error="")
            self.store.save()
            try:
                destination = convert_path(
                    source,
                    library_root=self.library_root,
                    lock_root=self.lock_root,
                    runner=self.runner,
                )
            except ConversionBusy:
                job.update(status="settling", updated_at=self.now())
                continue
            except (EbookConverterError, OSError) as exc:
                expected_destination = source.with_suffix(".epub")
                if not source.exists() and expected_destination.exists():
                    try:
                        validate_epub(expected_destination)
                    except EbookConverterError:
                        pass
                    else:
                        job.update(
                            status="complete",
                            destination=str(expected_destination),
                            updated_at=self.now(),
                            error="",
                        )
                        continue
                attempts = int(job.get("attempts", 0)) + 1
                status_name = (
                    "needs_attention" if attempts >= self.max_attempts else "failed"
                )
                job.update(
                    status=status_name,
                    attempts=attempts,
                    updated_at=self.now(),
                    error=str(exc),
                )
                self.store.data["totals"]["failed"] = (
                    int(self.store.data["totals"].get("failed", 0)) + 1
                )
                LOG.error(
                    "ebook conversion failed: source=%s attempts=%d error=%s",
                    source,
                    attempts,
                    exc,
                )
            else:
                finished = self.now()
                job.update(
                    status="complete",
                    destination=str(destination),
                    updated_at=finished,
                    error="",
                )
                self.store.data["totals"]["success"] = (
                    int(self.store.data["totals"].get("success", 0)) + 1
                )
                self.store.data["last_success"] = finished
            finally:
                self.store.save()

        self.store.save()


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


def watch_command(args: argparse.Namespace) -> int:
    try:
        store = StateStore(Path(args.state_file))
        service = EbookConverterService(
            library_root=Path(args.library_root),
            lock_root=Path(args.lock_root),
            store=store,
            runner=CalibreRunner(),
            settle_seconds=args.settle_seconds,
            max_attempts=args.max_attempts,
        )
    except (EbookConverterError, OSError) as exc:
        LOG.error("failed to initialize ebook converter service: %s", exc)
        return 1

    while True:
        ok = True
        try:
            service.iteration()
        except Exception:
            ok = False
            LOG.exception("ebook converter iteration failed")
        try:
            atomic_write_text(
                Path(args.metrics_file),
                prometheus_metrics(store, ok, time.time()),
            )
        except OSError:
            ok = False
            LOG.exception("failed to write ebook converter metrics")

        if args.once:
            return 0 if ok else 1
        time.sleep(args.interval_seconds)


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

    watch_parser = subparsers.add_parser(
        "watch", help="poll a library root for stable MOBI/AZW3 files"
    )
    watch_parser.add_argument("--library-root", required=True)
    watch_parser.add_argument("--lock-root", required=True)
    watch_parser.add_argument("--state-file", required=True)
    watch_parser.add_argument("--metrics-file", required=True)
    watch_parser.add_argument("--interval-seconds", type=float, default=30.0)
    watch_parser.add_argument("--settle-seconds", type=float, default=30.0)
    watch_parser.add_argument("--max-attempts", type=int, default=3)
    watch_parser.add_argument("--once", action="store_true")
    watch_parser.set_defaults(handler=watch_command)
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
