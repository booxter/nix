from __future__ import annotations

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
import zlib
from collections.abc import Callable, Iterable, Iterator, Mapping, Sequence
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol, TextIO

from atomic_file_writes import write_text_atomic
from pydantic import ValidationError

from .metrics import prometheus_metrics
from .models import FileFingerprint, JobState, ServiceState, ShelfmarkPayload

LOG = logging.getLogger("ebook-converter")
SOURCE_PRIORITY = {".azw3": 0, ".mobi": 1}
JOB_POLICY_VERSION = 3


class EbookConverterError(RuntimeError):
    pass


class InvalidEpub(EbookConverterError):
    pass


class ConversionBusy(EbookConverterError):
    pass


@dataclass(frozen=True)
class ShelfmarkHookConfig:
    library_root: Path
    state_dir: Path

    @classmethod
    def from_environment(cls, environment: Mapping[str, str]) -> ShelfmarkHookConfig:
        def required_path(name: str) -> Path:
            value = environment.get(name)
            if not value:
                raise EbookConverterError(f"required environment variable is unset: {name}")
            return Path(value)

        return cls(
            library_root=required_path("EBOOK_CONVERTER_LIBRARY_ROOT"),
            state_dir=required_path("EBOOK_CONVERTER_STATE_DIR"),
        )

    def converter_environment(self, environment: Mapping[str, str]) -> dict[str, str]:
        configured = dict(environment)
        configured["XDG_CONFIG_HOME"] = str(self.state_dir)
        return configured


class Converter(Protocol):
    def convert(self, source: Path, destination: Path) -> None: ...


class ConverterRunner:
    def __init__(
        self,
        executable: str = "ebook-converter",
        environment: Mapping[str, str] | None = None,
    ):
        self.executable = executable
        self.environment = dict(environment) if environment is not None else None

    def convert(self, source: Path, destination: Path) -> None:
        try:
            subprocess.run(
                [self.executable, str(source), str(destination)],
                check=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                env=self.environment,
            )
        except subprocess.CalledProcessError as exc:
            output = exc.stdout.strip() if exc.stdout else "no converter output"
            raise EbookConverterError(
                f"ebook conversion failed for {source.name}: {output[-1000:]}"
            ) from exc


def is_within(path: Path, root: Path) -> bool:
    try:
        path.relative_to(root)
    except ValueError:
        return False
    return True


def validate_epub(path: Path) -> None:
    try:
        file_stat = path.stat()
    except FileNotFoundError as exc:
        raise InvalidEpub(f"missing EPUB: {path}") from exc

    if not stat.S_ISREG(file_stat.st_mode) or file_stat.st_size == 0:
        raise InvalidEpub(f"empty EPUB: {path}")

    try:
        with zipfile.ZipFile(path) as archive:
            if archive.testzip() is not None:
                raise InvalidEpub(f"corrupt EPUB: {path}")
            names = set(archive.namelist())
            if "mimetype" not in names:
                raise InvalidEpub(f"EPUB has no mimetype entry: {path}")
            if archive.read("mimetype") != b"application/epub+zip":
                raise InvalidEpub(f"EPUB has an invalid mimetype: {path}")
            if "META-INF/container.xml" not in names:
                raise InvalidEpub(f"EPUB has no container metadata: {path}")
    except (zipfile.BadZipFile, zlib.error) as exc:
        raise InvalidEpub(f"invalid EPUB: {path}") from exc


def regular_file_fingerprint(path: Path) -> FileFingerprint | None:
    try:
        file_stat = path.lstat()
    except FileNotFoundError:
        return None
    if not stat.S_ISREG(file_stat.st_mode):
        raise EbookConverterError(f"refusing non-regular ebook file: {path}")
    return FileFingerprint(
        device=file_stat.st_dev,
        inode=file_stat.st_ino,
        size=file_stat.st_size,
        mtime_ns=file_stat.st_mtime_ns,
    )


@contextmanager
def conversion_lock(destination: Path, lock_root: Path) -> Iterator[None]:
    lock_root.mkdir(parents=True, exist_ok=True)
    lock_name = hashlib.sha256(os.fsencode(destination)).hexdigest() + ".lock"
    lock_path = lock_root / lock_name
    fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o660)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise ConversionBusy(f"conversion is already active for {destination}") from exc
        yield
    finally:
        os.close(fd)


def group_sources(paths: Iterable[Path]) -> dict[Path, list[Path]]:
    groups: dict[Path, list[Path]] = {}
    for path in dict.fromkeys(paths):
        if path.suffix.lower() in SOURCE_PRIORITY:
            groups.setdefault(path.with_suffix(".epub"), []).append(path)
    return groups


def ensure_epub(destination: Path, sources: Sequence[Path], runner: Converter) -> None:
    existing = regular_file_fingerprint(destination)
    errors: list[str] = []
    if existing is not None:
        try:
            validate_epub(destination)
        except InvalidEpub as exc:
            errors.append(str(exc))
        else:
            return

    for source in sorted(sources, key=lambda path: (SOURCE_PRIORITY[path.suffix.lower()], path)):
        temporary_epub = destination.with_name(
            f".{destination.stem}.{uuid.uuid4().hex}.ebook-converter-partial.epub"
        )
        source_mode = stat.S_IMODE(source.stat().st_mode)
        try:
            runner.convert(source, temporary_epub)
            validate_epub(temporary_epub)
        except EbookConverterError as exc:
            errors.append(str(exc))
        else:
            temporary_epub.chmod(source_mode)
            with temporary_epub.open("rb") as output_file:
                os.fsync(output_file.fileno())
            if regular_file_fingerprint(destination) != existing:
                raise EbookConverterError(
                    f"refusing to replace EPUB changed during conversion: {destination}"
                )
            temporary_epub.replace(destination)
            LOG.info("converted ebook: source=%s destination=%s", source, destination)
            return
        finally:
            temporary_epub.unlink(missing_ok=True)

    details = "; ".join(errors) or "no source files remain"
    raise EbookConverterError(f"no usable ebook for {destination}: {details}")


def convert_book(
    destination: Path,
    sources: Sequence[Path],
    *,
    library_root: Path,
    lock_root: Path,
    runner: Converter,
) -> Path:
    library_root = library_root.resolve(strict=True)
    destination = destination.parent.resolve(strict=True) / destination.name
    if not is_within(destination, library_root):
        raise EbookConverterError(f"ebook is outside the configured library root: {destination}")

    # All formats for a book share an output, so the hook and watcher lock that path.
    with conversion_lock(destination, lock_root):
        local_sources = [destination.with_name(source.name) for source in sources]
        available = [source for source in local_sources if regular_file_fingerprint(source)]
        ensure_epub(destination, available, runner)
        for source in available:
            source.unlink(missing_ok=True)
    return destination


def process_hook_payload(
    payload: object,
    *,
    library_root: Path,
    lock_root: Path,
    runner: Converter,
) -> list[Path]:
    try:
        hook = ShelfmarkPayload.model_validate(payload)
    except ValidationError as exc:
        raise EbookConverterError(f"invalid Shelfmark hook payload: {exc}") from exc
    if hook.phase != "post_transfer":
        LOG.info("ignoring Shelfmark hook phase %r", hook.phase)
        return []

    if hook.output is None or hook.output.mode != "folder":
        LOG.info("ignoring non-folder Shelfmark output")
        return []

    if hook.paths is None:
        raise EbookConverterError("Shelfmark hook payload has invalid final paths")

    groups = group_sources(map(Path, hook.paths.final_paths))
    return [
        convert_book(
            destination,
            sources,
            library_root=library_root,
            lock_root=lock_root,
            runner=runner,
        )
        for destination, sources in groups.items()
    ]


def discover_sources(library_root: Path) -> list[Path]:
    candidates = []
    for path in library_root.rglob("*"):
        relative = path.relative_to(library_root)
        if any(part.startswith(".") for part in relative.parts):
            continue
        if path.is_file() and not path.is_symlink() and path.suffix.lower() in SOURCE_PRIORITY:
            candidates.append(path)
    return sorted(candidates, key=lambda path: str(path).casefold())


class StateStore:
    def __init__(self, path: Path) -> None:
        self.path = path
        self.data = self.default_data()
        self.load()

    @staticmethod
    def default_data() -> ServiceState:
        return ServiceState()

    def load(self) -> None:
        if not self.path.exists():
            return
        try:
            self.data = ServiceState.model_validate_json(self.path.read_text(encoding="utf-8"))
        except (ValidationError, OSError) as exc:
            raise EbookConverterError(f"failed to read state file {self.path}: {exc}") from exc

    def save(self) -> None:
        write_text_atomic(
            self.path,
            self.data.model_dump_json(indent=2) + "\n",
            mode=0o660,
        )


class EbookConverterService:
    def __init__(
        self,
        *,
        library_root: Path,
        lock_root: Path,
        store: StateStore,
        runner: Converter,
        settle_seconds: float,
        max_attempts: int,
        now: Callable[[], float] = time.time,
    ) -> None:
        self.library_root = library_root.resolve(strict=True)
        self.lock_root = lock_root
        self.store = store
        self.runner = runner
        self.settle_seconds = settle_seconds
        self.max_attempts = max_attempts
        self.now = now

    def settled_job(self, source: Path, now: float) -> JobState | None:
        fingerprint = regular_file_fingerprint(source)
        if fingerprint is None:
            return None

        files = self.store.data.files
        key = str(source)
        job = files.get(key)
        if (
            job is None
            or job.fingerprint != fingerprint
            or job.policy_version != JOB_POLICY_VERSION
        ):
            files[key] = JobState(
                status="settling",
                fingerprint=fingerprint,
                policy_version=JOB_POLICY_VERSION,
                observed_at=now,
                updated_at=now,
            )
            return None

        if now - job.observed_at < self.settle_seconds:
            return None
        return job

    def convert_group(self, destination: Path, jobs: Mapping[Path, JobState], now: float) -> None:
        for job in jobs.values():
            job.status = "converting"
            job.updated_at = now
            job.error = ""
        self.store.save()

        try:
            destination = convert_book(
                destination,
                list(jobs),
                library_root=self.library_root,
                lock_root=self.lock_root,
                runner=self.runner,
            )
        except ConversionBusy:
            for job in jobs.values():
                job.status = "settling"
        except (EbookConverterError, OSError) as exc:
            # A new or changed source gives the group a fresh set of attempts.
            attempts = min(job.attempts for job in jobs.values()) + 1
            status = "needs_attention" if attempts >= self.max_attempts else "failed"
            removed = [source for source in jobs if not source.exists()]
            if removed:
                try:
                    validate_epub(destination)
                except (InvalidEpub, OSError):
                    removed = []

            for source, job in jobs.items():
                if source in removed:
                    job.status = "complete"
                    job.destination = str(destination)
                    continue
                job.status = status
                job.attempts = attempts
                job.error = str(exc)
            self.store.data.totals.failed += 1
            LOG.error(
                "ebook conversion failed: destination=%s attempts=%d error=%s",
                destination,
                attempts,
                exc,
            )
        else:
            for job in jobs.values():
                job.status = "complete"
                job.destination = str(destination)
            self.store.data.totals.success += 1
            self.store.data.last_success = self.now()
        finally:
            updated_at = self.now()
            for job in jobs.values():
                job.updated_at = updated_at
            self.store.save()

    def iteration(self) -> None:
        now = self.now()
        for destination, sources in group_sources(discover_sources(self.library_root)).items():
            jobs = {
                source: job
                for source in sources
                if (job := self.settled_job(source, now)) is not None
            }
            if len(jobs) != len(sources):
                continue
            if all(
                job.status == "needs_attention" and job.attempts >= self.max_attempts
                for job in jobs.values()
            ):
                continue
            self.convert_group(destination, jobs, now)

        self.store.save()


def run_hook(
    *,
    library_root: Path,
    lock_root: Path,
    stdin: TextIO,
    runner: Converter,
) -> int:
    try:
        payload = json.load(stdin)
        converted = process_hook_payload(
            payload,
            library_root=library_root,
            lock_root=lock_root,
            runner=runner,
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
            runner=ConverterRunner(),
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
            write_text_atomic(
                Path(args.metrics_file),
                prometheus_metrics(store.data, ok, time.time()),
                mode=0o644,
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
    parser.add_argument("--library-root", required=True)
    parser.add_argument("--lock-root", required=True)
    parser.add_argument("--state-file", required=True)
    parser.add_argument("--metrics-file", required=True)
    parser.add_argument("--interval-seconds", type=float, default=30.0)
    parser.add_argument("--settle-seconds", type=float, default=30.0)
    parser.add_argument("--max-attempts", type=int, default=3)
    parser.add_argument("--once", action="store_true")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv if argv is not None else sys.argv[1:])
    logging.basicConfig(
        level=getattr(logging, args.log_level),
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    return watch_command(args)


def shelfmark_hook_main(
    argv: list[str] | None = None,
    *,
    environment: Mapping[str, str] = os.environ,
    stdin: TextIO = sys.stdin,
    runner: Converter | None = None,
) -> int:
    hook_parser = argparse.ArgumentParser(
        prog="shelfmark-ebook-converter-hook",
        description="Convert ebooks from a Shelfmark post-transfer hook payload",
    )
    hook_parser.add_argument("target", help="target path supplied by Shelfmark")
    hook_parser.add_argument(
        "--log-level",
        default="INFO",
        choices=["DEBUG", "INFO", "WARNING", "ERROR"],
    )
    arguments = hook_parser.parse_args(argv)
    logging.basicConfig(
        level=getattr(logging, arguments.log_level),
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    try:
        config = ShelfmarkHookConfig.from_environment(environment)
    except EbookConverterError as exc:
        LOG.error("Shelfmark ebook conversion hook configuration failed: %s", exc)
        return 1
    converter = runner or ConverterRunner(environment=config.converter_environment(environment))
    return run_hook(
        library_root=config.library_root,
        lock_root=config.state_dir,
        stdin=stdin,
        runner=converter,
    )


if __name__ == "__main__":
    raise SystemExit(main())
