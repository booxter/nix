from __future__ import annotations

import re
import tarfile
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Protocol

import rarfile

from .errors import NeedsAttention, SourceInvalid
from .lidarr_pipeline import TransformResult
from .media import AUDIO_FILE_SUFFIXES


ARCHIVE_SUFFIXES = frozenset({".rar", ".tar"})
MULTIPART_RAR_RE = re.compile(r"\.part\d+\.rar$", re.IGNORECASE)
MAX_ARCHIVE_FILES = 10_000
MAX_EXPANDED_BYTES = 50 * 1024**3


@dataclass(frozen=True)
class ArchiveMember:
    name: str
    size: int
    is_directory: bool
    is_link: bool


class ArchiveBackend(Protocol):
    def members(self, archive: Path) -> list[ArchiveMember]: ...

    def extract(self, archive: Path, destination: Path) -> None: ...


class NativeArchiveBackend:
    def members(self, archive: Path) -> list[ArchiveMember]:
        if archive.suffix.lower() == ".tar":
            return self.tar_members(archive)
        return self.rar_members(archive)

    @staticmethod
    def tar_members(archive: Path) -> list[ArchiveMember]:
        try:
            with tarfile.open(archive, mode="r:") as source:
                return [
                    ArchiveMember(
                        name=member.name,
                        size=member.size,
                        is_directory=member.isdir(),
                        is_link=member.issym() or member.islnk(),
                    )
                    for member in source.getmembers()
                ]
        except (OSError, tarfile.TarError) as error:
            raise SourceInvalid(f"cannot read TAR archive {archive}: {error}") from error

    @staticmethod
    def rar_members(archive: Path) -> list[ArchiveMember]:
        try:
            with rarfile.RarFile(archive) as source:
                if source.needs_password():
                    raise NeedsAttention(f"RAR archive is encrypted: {archive}")
                return [
                    ArchiveMember(
                        name=str(member.filename),
                        size=int(member.file_size),
                        is_directory=bool(member.isdir()),
                        is_link=bool(member.is_symlink()),
                    )
                    for member in source.infolist()
                ]
        except NeedsAttention:
            raise
        except (OSError, rarfile.Error) as error:
            raise SourceInvalid(f"cannot read RAR archive {archive}: {error}") from error

    def extract(self, archive: Path, destination: Path) -> None:
        try:
            if archive.suffix.lower() == ".tar":
                with tarfile.open(archive, mode="r:") as source:
                    source.extractall(destination, filter="data")
                return
            with rarfile.RarFile(archive) as source:
                source.extractall(destination)
        except (OSError, tarfile.TarError, rarfile.Error) as error:
            raise SourceInvalid(f"cannot extract archive {archive}: {error}") from error


class ArchiveTransform:
    name = "archive_extract"
    input_suffixes = ARCHIVE_SUFFIXES | AUDIO_FILE_SUFFIXES

    def __init__(
        self,
        backend: ArchiveBackend,
        *,
        max_files: int = MAX_ARCHIVE_FILES,
        max_expanded_bytes: int = MAX_EXPANDED_BYTES,
    ):
        self.backend = backend
        self.max_files = max_files
        self.max_expanded_bytes = max_expanded_bytes

    @staticmethod
    def archives(source: Path) -> list[Path]:
        return sorted(
            path
            for path in source.rglob("*")
            if path.is_file() and path.suffix.lower() in ARCHIVE_SUFFIXES
        )

    def candidate(self, source: Path) -> Path | None:
        archives = self.archives(source)
        if not archives:
            return None
        if len(archives) != 1:
            names = ", ".join(path.name for path in archives)
            raise NeedsAttention(f"download contains multiple archives: {names}")
        archive = archives[0]
        if MULTIPART_RAR_RE.search(archive.name):
            raise NeedsAttention(f"multipart RAR archives are not supported: {archive.name}")
        standalone_audio = [
            path
            for path in source.rglob("*")
            if path.is_file() and path.suffix.lower() in AUDIO_FILE_SUFFIXES
        ]
        return None if standalone_audio else archive

    def applies(self, source: Path) -> bool:
        return self.candidate(source) is not None

    @staticmethod
    def validate_member_path(name: str) -> None:
        normalized = name.replace("\\", "/")
        path = PurePosixPath(normalized)
        if (
            not normalized
            or path.is_absolute()
            or ".." in path.parts
            or (path.parts and ":" in path.parts[0])
        ):
            raise SourceInvalid(f"archive contains unsafe path: {name!r}")

    def validate_members(self, archive: Path, members: list[ArchiveMember]) -> None:
        files = [member for member in members if not member.is_directory]
        if not files:
            raise SourceInvalid(f"archive contains no files: {archive}")
        if len(files) > self.max_files:
            raise SourceInvalid(
                f"archive contains {len(files)} files; limit is {self.max_files}: {archive}"
            )
        expanded_bytes = sum(member.size for member in files)
        if expanded_bytes > self.max_expanded_bytes:
            raise SourceInvalid(
                f"archive expands to {expanded_bytes} bytes; limit is "
                f"{self.max_expanded_bytes}: {archive}"
            )
        for member in members:
            self.validate_member_path(member.name)
            if member.is_link:
                raise SourceInvalid(f"archive contains a link: {member.name}")

    @staticmethod
    def validate_extracted_tree(destination: Path) -> None:
        for path in destination.rglob("*"):
            if path.is_symlink() or not (path.is_file() or path.is_dir()):
                raise SourceInvalid(f"archive extracted an unsafe filesystem object: {path}")

    def apply(self, source: Path, destination: Path) -> TransformResult:
        archive = self.candidate(source)
        if archive is None:
            raise SourceInvalid("archive transformation is no longer applicable")
        members = self.backend.members(archive)
        self.validate_members(archive, members)
        destination.mkdir(parents=True)
        self.backend.extract(archive, destination)
        self.validate_extracted_tree(destination)
        artifacts = sum(not member.is_directory for member in members)
        return TransformResult(root=destination, artifacts=artifacts)
