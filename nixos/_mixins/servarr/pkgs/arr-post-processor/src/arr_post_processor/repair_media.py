from __future__ import annotations

import hashlib
import re
from pathlib import Path

from .errors import ManualMatchRequired
from .models import ManualImportCandidate, ManualImportFile, QueueRecord

STAGING_DIR_NAME = "_arr-post-processor"
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


def safe_component(value: str) -> str:
    readable = re.sub(r"[^A-Za-z0-9._-]+", "-", value).strip("-.")[:48] or "download"
    digest = hashlib.sha256(value.encode()).hexdigest()[:12]
    return f"{readable}-{digest}"


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
