from __future__ import annotations

import hashlib
import re
import subprocess
from pathlib import Path
from typing import Callable

from pydantic import TypeAdapter, ValidationError

from .errors import ManualMatchRequired, SourceInvalid
from .models import (
    CueSummary,
    ManualImportCandidate,
    ManualImportFile,
    QueueRecord,
    UnflacInput,
)


STAGING_DIR_NAME = "_lidarr-cue-split"
AUDIO_FILE_SUFFIXES = {
    ".aac",
    ".aif",
    ".aiff",
    ".alac",
    ".ape",
    ".dff",
    ".dsf",
    ".flac",
    ".m4a",
    ".mka",
    ".mp3",
    ".mpc",
    ".ogg",
    ".opus",
    ".tak",
    ".tta",
    ".wav",
    ".wave",
    ".wma",
    ".wv",
}
CUE_FILE_COMMAND_RE = re.compile(r'^\s*FILE\s+(?:"([^"]+)"|(\S+))\s+\S+', re.IGNORECASE)
CUE_TRACK_COMMAND_RE = re.compile(r"^\s*TRACK\s+\d+\s+\S+", re.IGNORECASE)
UNFLAC_INSPECTIONS = TypeAdapter(list[UnflacInput])


def is_within(path: Path, roots: list[Path]) -> bool:
    resolved = path.resolve()
    return any(
        resolved == root.resolve() or resolved.is_relative_to(root.resolve()) for root in roots
    )


def safe_component(value: str) -> str:
    readable = re.sub(r"[^A-Za-z0-9._-]+", "-", value).strip("-.")[:48] or "download"
    digest = hashlib.sha256(value.encode()).hexdigest()[:12]
    return f"{readable}-{digest}"


def resolve_cue_audio_reference(cue: Path, reference: str) -> Path | None:
    referenced = Path(reference)
    candidate = referenced if referenced.is_absolute() else cue.parent / referenced
    try:
        if candidate.is_file():
            return candidate.resolve()
        matches = sorted(
            path.resolve()
            for path in candidate.parent.iterdir()
            if path.is_file()
            and path.stem == candidate.stem
            and path.suffix.lower() in AUDIO_FILE_SUFFIXES
        )
    except (OSError, RuntimeError):
        return None
    return matches[0] if len(matches) == 1 else None


def cue_already_split_audio_files(cue: Path) -> list[Path] | None:
    try:
        content = cue.read_bytes().decode("utf-8-sig", errors="surrogateescape")
    except OSError:
        return None

    references: list[str] = []
    track_count = 0
    for line in content.splitlines():
        file_match = CUE_FILE_COMMAND_RE.match(line)
        if file_match:
            references.append(file_match.group(1) or file_match.group(2))
        if CUE_TRACK_COMMAND_RE.match(line):
            track_count += 1

    if not references or len(references) != track_count:
        return None
    audio_files: list[Path] = []
    for reference in references:
        audio_file = resolve_cue_audio_reference(cue, reference)
        if audio_file is None:
            return None
        audio_files.append(audio_file)
    if len(set(audio_files)) != track_count:
        return None
    return audio_files


class UnflacRunner:
    def __init__(self, run: Callable[..., subprocess.CompletedProcess[str]] = subprocess.run):
        self.run = run

    def inspect(self, cue: Path) -> list[UnflacInput]:
        result = self.run(
            ["unflac", "-d", "-j", str(cue)],
            check=False,
            capture_output=True,
            text=True,
            errors="replace",
        )
        if result.returncode != 0:
            raise SourceInvalid(f"unflac could not parse {cue}: {result.stderr.strip()}")
        try:
            payload = UNFLAC_INSPECTIONS.validate_json(result.stdout)
        except ValidationError as error:
            raise SourceInvalid(f"unflac returned invalid inspection JSON for {cue}") from error
        if not payload:
            raise SourceInvalid(f"unflac found no input in {cue}")
        return payload

    def split(self, cue: Path, output_dir: Path) -> list[Path]:
        result = self.run(
            ["unflac", "-f", "flac", "-o", str(output_dir), str(cue)],
            check=False,
            capture_output=True,
            text=True,
            errors="replace",
        )
        if result.returncode != 0:
            raise SourceInvalid(f"unflac failed for {cue}: {result.stderr.strip()}")
        return sorted(path.resolve() for path in output_dir.rglob("*.flac") if path.is_file())

    def verify_flac(self, path: Path) -> None:
        result = self.run(
            ["flac", "--silent", "--test", str(path)],
            check=False,
            capture_output=True,
            text=True,
            errors="replace",
        )
        if result.returncode != 0:
            raise SourceInvalid(f"FLAC verification failed for {path}: {result.stderr.strip()}")


def inspection_summary(cue: Path, payload: list[UnflacInput]) -> CueSummary:
    audio_files: list[Path] = []
    track_count = 0
    has_image = False
    for item in payload:
        for audio in item.audio:
            path = audio.path
            if not path.is_absolute():
                path = cue.parent / path
            audio_files.append(path.resolve())
            track_count += len(audio.tracks)
            has_image = has_image or len(audio.tracks) > 1
    if not audio_files or track_count == 0:
        raise SourceInvalid(f"unflac inspection found no audio tracks for {cue}")
    return CueSummary(
        cue=cue.resolve(),
        audio_files=tuple(audio_files),
        track_count=track_count,
        eligible=has_image,
    )


def source_fingerprint(summaries: list[CueSummary]) -> str:
    entries: list[str] = []
    paths: set[Path] = set()
    for summary in summaries:
        paths.add(summary.cue)
        paths.update(summary.audio_files)
    for path in sorted(paths):
        stat = path.stat()
        entries.append(f"{path}\0{stat.st_size}\0{stat.st_mtime_ns}")
    return hashlib.sha256("\n".join(entries).encode()).hexdigest()


def output_fingerprint(output_path: Path) -> str:
    if not output_path.is_dir():
        return f"missing:{output_path}"
    entries: list[str] = []
    try:
        for path in sorted(output_path.rglob("*")):
            if (
                not path.is_file()
                or STAGING_DIR_NAME in path.parts
                or (
                    path.suffix.lower() != ".cue" and path.suffix.lower() not in AUDIO_FILE_SUFFIXES
                )
            ):
                continue
            stat = path.stat()
            entries.append(f"{path.relative_to(output_path)}\0{stat.st_size}\0{stat.st_mtime_ns}")
    except OSError as error:
        return f"unreadable:{output_path}:{error}"
    return hashlib.sha256("\n".join(entries).encode()).hexdigest()


def build_manual_import_files(
    outputs: list[ManualImportCandidate],
    generated_files: list[Path],
    record: QueueRecord,
) -> list[ManualImportFile]:
    generated = {path.resolve() for path in generated_files}
    selected: dict[Path, ManualImportFile] = {}
    for output in outputs:
        path = output.path.resolve()
        if path not in generated:
            continue
        if output.rejections:
            reasons = "; ".join(item.reason for item in output.rejections)
            raise ManualMatchRequired(f"Lidarr rejected {path.name}: {reasons}")
        artist_id = output.artist.id
        album_id = output.album.id
        if record.artist_id and artist_id != record.artist_id:
            raise ManualMatchRequired(
                f"Lidarr matched {path.name} to artist {artist_id}, expected {record.artist_id}"
            )
        if record.album_id and album_id != record.album_id:
            raise ManualMatchRequired(
                f"Lidarr matched {path.name} to album {album_id}, expected {record.album_id}"
            )
        track_ids = [track.id for track in output.tracks if track.id]
        if not track_ids:
            raise ManualMatchRequired(f"Lidarr did not match {path.name} to a track")
        selected[path] = ManualImportFile(
            path=path,
            artist_id=artist_id,
            album_id=album_id,
            album_release_id=output.album_release_id,
            track_ids=track_ids,
            quality=output.quality,
            download_id=output.download_id or record.download_id,
            disable_release_switching=output.disable_release_switching,
        )
    missing = generated - selected.keys()
    if missing:
        names = ", ".join(sorted(path.name for path in missing))
        raise ManualMatchRequired(f"Lidarr did not return every generated track: {names}")
    return [selected[path] for path in sorted(selected)]
