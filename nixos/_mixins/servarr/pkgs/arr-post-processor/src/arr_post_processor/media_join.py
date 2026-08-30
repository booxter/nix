from __future__ import annotations

import hashlib
import os
import re
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Protocol

from pydantic import BaseModel, Field, ValidationError

from .errors import NeedsAttention, SourceInvalid
from .media import is_within, safe_component
from .radarr_models import RadarrMovie, RadarrQueueRecord


VIDEO_SUFFIXES = {".avi", ".mkv", ".mp4"}
EXTRA_RE = re.compile(
    r"(?i)(?:^|[ ._\-])(bonus|bloopers?|bts|behind[ ._\-]+the[ ._\-]+scenes?|"
    r"interviews?|menus?|samples?|trailers?|featurettes?|extras?|preview|promo)(?:[ ._\-]|$)"
)
EPISODE_RE = re.compile(
    r"(?i)(?:\bseason\b|\bS\d{1,2}E\d{1,3}\b|(?:^|[ ._\-])S\d{1,2}(?:[ ._\-]|$))"
)
MARKED_PART_RE = re.compile(
    r"(?i)(?:^|[ ._\-])(?:cd|disc|part|scene|chapter|episode|номер)[ ._\-]*0*(\d+)([a-z]?)(?:[ ._\-]|$)"
)
NUMBER_RE = re.compile(r"\d+")


class ProbeStream(BaseModel):
    codec_name: str
    codec_type: str
    width: int | None = None
    height: int | None = None
    channels: int | None = None


class ProbeFormat(BaseModel):
    duration: str


class ProbeResponse(BaseModel):
    streams: list[ProbeStream] = Field(default_factory=list)
    format: ProbeFormat


@dataclass(frozen=True)
class MediaProbe:
    duration_seconds: float
    signature: tuple[tuple[str, str, int | None, int | None, int | None], ...]


@dataclass(frozen=True)
class JoinPlan:
    parts: tuple[Path, ...]
    probes: tuple[MediaProbe, ...]
    fingerprint: str
    expected_duration_seconds: float
    output_extension: str

    @property
    def source_duration_seconds(self) -> float:
        return sum(probe.duration_seconds for probe in self.probes)


@dataclass(frozen=True)
class SingleFilePlan:
    path: Path
    probe: MediaProbe


class JoinBackend(Protocol):
    def probe(self, path: Path) -> MediaProbe: ...

    def join(self, parts: tuple[Path, ...], output: Path) -> None: ...


class CommandJoinBackend:
    def __init__(
        self,
        *,
        ffprobe: str | None = None,
        joiner: str | None = None,
        timeout_seconds: float = 3600,
        run: Callable[..., subprocess.CompletedProcess[str]] = subprocess.run,
    ):
        self.ffprobe = ffprobe or os.environ["ARR_POST_PROCESSOR_FFPROBE"]
        self.joiner = joiner or os.environ["ARR_POST_PROCESSOR_JOIN_MEDIA_PARTS"]
        self.timeout_seconds = timeout_seconds
        self.run = run

    def probe(self, path: Path) -> MediaProbe:
        result = self.run(
            [
                self.ffprobe,
                "-v",
                "error",
                "-show_entries",
                "format=duration:stream=codec_name,codec_type,width,height,channels",
                "-of",
                "json",
                str(path),
            ],
            check=False,
            capture_output=True,
            text=True,
            errors="replace",
            timeout=self.timeout_seconds,
        )
        if result.returncode != 0:
            raise SourceInvalid(f"ffprobe failed for {path}: {result.stderr.strip()}")
        try:
            payload = ProbeResponse.model_validate_json(result.stdout)
            duration = float(payload.format.duration)
        except (ValidationError, ValueError) as error:
            raise SourceInvalid(f"ffprobe returned invalid media metadata for {path}") from error
        if duration <= 0:
            raise SourceInvalid(f"media part has no positive duration: {path}")
        signature = tuple(
            (
                stream.codec_type,
                stream.codec_name,
                stream.width,
                stream.height,
                stream.channels,
            )
            for stream in payload.streams
        )
        if not any(stream[0] == "video" for stream in signature):
            raise SourceInvalid(f"media part has no video stream: {path}")
        return MediaProbe(duration_seconds=duration, signature=signature)

    def join(self, parts: tuple[Path, ...], output: Path) -> None:
        arguments = [self.joiner]
        for part in parts:
            arguments.extend(["--part", str(part)])
        arguments.extend(["--output", str(output)])
        result = self.run(
            arguments,
            check=False,
            capture_output=True,
            text=True,
            errors="replace",
            timeout=self.timeout_seconds,
        )
        if result.returncode != 0:
            raise SourceInvalid(f"media join failed: {result.stderr.strip()}")


def _marked_order(paths: list[Path]) -> list[Path] | None:
    marked = [(path, MARKED_PART_RE.search(path.stem)) for path in paths]
    unmatched = [path for path, match in marked if match is None]
    matched = [(path, match) for path, match in marked if match is not None]
    if not matched or len(unmatched) > 1:
        return None
    keys = [(int(match.group(1)), match.group(2).lower() or " ") for _, match in matched]
    if len(set(keys)) != len(keys):
        return None
    ordered = [path for _, path in sorted(zip(keys, (path for path, _ in matched)))]
    if not unmatched:
        first_numbers = sorted({number for number, _ in keys})
        if first_numbers != list(range(1, max(first_numbers) + 1)):
            return None
        return ordered
    numbers = sorted(number for number, suffix in keys if suffix == " ")
    if len(numbers) != len(keys) or numbers != list(range(2, len(paths) + 1)):
        return None
    return unmatched + ordered


def _numeric_order(paths: list[Path]) -> list[Path] | None:
    tokens = [[int(match.group()) for match in NUMBER_RE.finditer(path.stem)] for path in paths]
    if not tokens or any(len(values) != len(tokens[0]) for values in tokens):
        return None
    for index in range(len(tokens[0]) - 1, -1, -1):
        values = [items[index] for items in tokens]
        if sorted(values) != list(range(1, len(paths) + 1)):
            continue
        return [path for _, path in sorted(zip(values, paths))]
    return None


def ordered_primary_parts(output_path: Path) -> tuple[Path, ...] | None:
    all_videos = sorted(
        path.resolve()
        for path in output_path.rglob("*")
        if path.is_file() and path.suffix.lower() in VIDEO_SUFFIXES
    )
    if len(all_videos) < 2 or any(path.parent != output_path.resolve() for path in all_videos):
        return None
    if EPISODE_RE.search(output_path.name) or any(
        EPISODE_RE.search(path.name) for path in all_videos
    ):
        return None
    primary = [path for path in all_videos if EXTRA_RE.search(path.stem) is None]
    if len(primary) < 2 or len({path.suffix.lower() for path in primary}) != 1:
        return None
    ordered = _marked_order(primary) or _numeric_order(primary)
    return tuple(ordered) if ordered is not None else None


def build_join_plan(
    record: RadarrQueueRecord,
    movie: RadarrMovie,
    allowed_roots: list[Path],
    backend: JoinBackend,
) -> JoinPlan | None:
    if record.output_path is None:
        return None
    output_path = record.output_path.resolve()
    if not is_within(output_path, allowed_roots):
        raise NeedsAttention(f"download path is outside allowed roots: {output_path}")
    if not output_path.is_dir():
        return None
    if (output_path / "BDMV").exists() or any(output_path.rglob("*.m2ts")):
        return None
    parts = ordered_primary_parts(output_path)
    if parts is None or movie.runtime <= 0:
        return None
    probes = tuple(backend.probe(path) for path in parts)
    if any(probe.signature != probes[0].signature for probe in probes[1:]):
        raise SourceInvalid("multipart stream layouts are not compatible")
    expected = float(movie.runtime * 60)
    actual = sum(probe.duration_seconds for probe in probes)
    tolerance = max(300.0, expected * 0.05)
    if abs(actual - expected) > tolerance:
        return None
    entries = []
    for path in parts:
        stat = path.stat()
        entries.append(f"{path}\0{stat.st_size}\0{stat.st_mtime_ns}")
    fingerprint = hashlib.sha256("\n".join(entries).encode()).hexdigest()
    extension = "mp4" if parts[0].suffix.lower() == ".mp4" else "mkv"
    return JoinPlan(
        parts=parts,
        probes=probes,
        fingerprint=fingerprint,
        expected_duration_seconds=expected,
        output_extension=extension,
    )


def build_single_file_plan(
    record: RadarrQueueRecord,
    movie: RadarrMovie,
    allowed_roots: list[Path],
    backend: JoinBackend,
) -> SingleFilePlan | None:
    if record.output_path is None:
        return None
    output_path = record.output_path.resolve()
    if not is_within(output_path, allowed_roots):
        raise NeedsAttention(f"download path is outside allowed roots: {output_path}")
    if output_path.is_file():
        videos = [output_path] if output_path.suffix.lower() in VIDEO_SUFFIXES else []
    elif output_path.is_dir():
        videos = sorted(
            path.resolve()
            for path in output_path.rglob("*")
            if path.is_file() and path.suffix.lower() in VIDEO_SUFFIXES
        )
    else:
        return None
    if len(videos) != 1 or not is_within(videos[0], allowed_roots) or movie.runtime <= 0:
        return None
    media_probe = backend.probe(videos[0])
    expected = float(movie.runtime * 60)
    tolerance = max(300.0, expected * 0.05)
    if abs(media_probe.duration_seconds - expected) > tolerance:
        return None
    return SingleFilePlan(path=videos[0], probe=media_probe)


def download_fingerprint(output_path: Path) -> str:
    if output_path.is_file():
        try:
            stat = output_path.stat()
        except OSError as error:
            return f"unreadable:{output_path}:{error}"
        entry = f"{output_path.name}\0{stat.st_size}\0{stat.st_mtime_ns}"
        return hashlib.sha256(entry.encode()).hexdigest()
    if not output_path.is_dir():
        return f"missing:{output_path}"
    entries = []
    try:
        for path in sorted(output_path.rglob("*")):
            if not path.is_file():
                continue
            stat = path.stat()
            entries.append(f"{path.relative_to(output_path)}\0{stat.st_size}\0{stat.st_mtime_ns}")
    except OSError as error:
        return f"unreadable:{output_path}:{error}"
    return hashlib.sha256("\n".join(entries).encode()).hexdigest()


def safe_output_name(record: RadarrQueueRecord, movie: RadarrMovie, extension: str) -> str:
    release = re.sub(r"[/\\\x00]", "-", record.title).strip(" .")
    if not release:
        release = f"{movie.title} ({movie.year})"
    return f"{release}.{extension}"


def prepare_joined_media(
    record: RadarrQueueRecord,
    movie: RadarrMovie,
    plan: JoinPlan,
    work_root: Path,
    backend: JoinBackend,
) -> Path:
    job_root = work_root.resolve() / safe_component(record.download_id)
    job_root.mkdir(parents=True, exist_ok=True)
    output = job_root / safe_output_name(record, movie, plan.output_extension)
    if output.exists():
        output.unlink()
    backend.join(plan.parts, output)
    probe = backend.probe(output)
    duration_tolerance = max(3.0, plan.source_duration_seconds * 0.01)
    if probe.signature != plan.probes[0].signature:
        output.unlink(missing_ok=True)
        raise SourceInvalid("joined output stream layout differs from its parts")
    if abs(probe.duration_seconds - plan.source_duration_seconds) > duration_tolerance:
        output.unlink(missing_ok=True)
        raise SourceInvalid("joined output duration differs from the sum of its parts")
    return output
