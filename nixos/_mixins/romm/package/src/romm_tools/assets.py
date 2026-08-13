from __future__ import annotations

import argparse
import os
import shutil
import sys
import tarfile
import tempfile
from collections.abc import Iterable, Sequence
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Protocol, TextIO, cast

from podman import PodmanClient
from podman.domain.containers import Container
from podman.errors import PodmanError
from pydantic import BaseModel, ConfigDict, Field, ValidationError
from requests import RequestException

MAX_MEMORY_ARCHIVE_BYTES = 8 * 1024 * 1024

HTML_PATH = "/var/www/html/."
NGINX_PATH = "/etc/nginx/js/."
ZIP_CACHE_PATH = "/backend/utils/zip_cache.py"

ZIP_CACHE_MARKER = b"        os.rename(tmp_path, target)"
ZIP_CACHE_REPLACEMENT = b"        os.chmod(tmp_path, 0o640)\n        os.rename(tmp_path, target)"


class Error(RuntimeError):
    pass


class ImageLoadResponse(BaseModel):
    model_config = ConfigDict(extra="allow", strict=True)

    names: list[str] = Field(alias="Names")


class ArchiveSource(Protocol):
    def archive(self, path: str) -> Iterable[bytes]: ...


@dataclass(frozen=True)
class AssetPaths:
    state_dir: Path

    @property
    def current(self) -> tuple[Path, Path, Path]:
        return (
            self.state_dir / "web",
            self.state_dir / "nginx",
            self.state_dir / "integration",
        )

    @property
    def staging(self) -> tuple[Path, Path, Path]:
        web, nginx, integration = self.current
        return (
            web.with_name(f"{web.name}.new"),
            nginx.with_name(f"{nginx.name}.new"),
            integration.with_name(f"{integration.name}.new"),
        )

    @property
    def previous(self) -> tuple[Path, Path, Path]:
        web, nginx, integration = self.current
        return (
            web.with_name(f"{web.name}.old"),
            nginx.with_name(f"{nginx.name}.old"),
            integration.with_name(f"{integration.name}.old"),
        )


class PodmanArchiveSource:
    def __init__(self, socket_url: str, image_ref: str, image_file: Path) -> None:
        self.socket_url = socket_url
        self.image_ref = image_ref
        self.image_file = image_file
        self.client: PodmanClient | None = None
        self.container: Container | None = None

    def __enter__(self) -> PodmanArchiveSource:
        try:
            self.client = PodmanClient(base_url=self.socket_url, timeout=300)
            # podman-py's public images.load(file_path=...) reads the entire OCI
            # archive into memory. Use its transport directly so requests streams
            # the store file to the same Libpod endpoint instead.
            with self.image_file.open("rb") as image:
                response = self.client.api.post(
                    "/images/load",
                    data=image,
                    headers={"Content-Type": "application/x-tar"},
                )
                response.raise_for_status()
                ImageLoadResponse.model_validate(response.json())
            self.container = self.client.containers.create(self.image_ref)
            return self
        except (OSError, PodmanError, RequestException, ValidationError, ValueError) as error:
            self.close()
            raise Error("failed to create the RomM asset container") from error

    def __exit__(self, *exception: object) -> None:
        self.close(raise_errors=exception[0] is None)

    def close(self, *, raise_errors: bool = False) -> None:
        cleanup_error: Exception | None = None
        if self.container is not None:
            try:
                self.container.remove(force=True)
            except (PodmanError, RequestException) as error:
                cleanup_error = error
            self.container = None
        if self.client is not None:
            self.client.api.close()
            self.client = None
        if cleanup_error is not None and raise_errors:
            raise Error("failed to remove the RomM asset container") from cleanup_error

    def archive(self, path: str) -> Iterable[bytes]:
        if self.container is None:
            raise Error("RomM asset container is not open")
        try:
            chunks, _ = self.container.get_archive(path)
            return cast(Iterable[bytes], chunks)
        except (PodmanError, RequestException) as error:
            raise Error(f"failed to read {path} from the RomM image") from error


def remove_path(path: Path) -> None:
    if path.is_symlink() or path.is_file():
        path.unlink()
    elif path.is_dir():
        shutil.rmtree(path)


def archive_filter(member: tarfile.TarInfo, destination: str) -> tarfile.TarInfo | None:
    normalized = PurePosixPath(member.name.removeprefix("./"))
    if normalized == PurePosixPath("assets/romm/resources"):
        return None
    return tarfile.data_filter(member, destination)


def extract_archive(chunks: Iterable[bytes], destination: Path) -> None:
    with tempfile.SpooledTemporaryFile(max_size=MAX_MEMORY_ARCHIVE_BYTES) as archive_file:
        for chunk in chunks:
            archive_file.write(chunk)
        archive_file.seek(0)
        try:
            with tarfile.open(fileobj=archive_file, mode="r:*") as archive:
                archive.extractall(destination, filter=archive_filter)
        except (tarfile.TarError, OSError) as error:
            raise Error(f"failed to extract RomM assets into {destination}") from error


def replace_required(path: Path, marker: bytes, replacement: bytes) -> None:
    contents = path.read_bytes()
    if marker not in contents:
        raise Error(f"required integration marker is missing from {path}")
    path.write_bytes(contents.replace(marker, replacement))


def publish(paths: AssetPaths) -> None:
    for previous in paths.previous:
        remove_path(previous)

    backed_up: list[tuple[Path, Path]] = []
    published: list[Path] = []
    try:
        for current, previous in zip(paths.current, paths.previous, strict=True):
            if current.exists() or current.is_symlink():
                os.replace(current, previous)
                backed_up.append((current, previous))
        for staging, current in zip(paths.staging, paths.current, strict=True):
            os.replace(staging, current)
            published.append(current)
    except OSError as error:
        for current in reversed(published):
            remove_path(current)
        for current, previous in reversed(backed_up):
            os.replace(previous, current)
        raise Error("failed to publish RomM integration assets") from error
    else:
        for previous in paths.previous:
            remove_path(previous)


def prepare_assets(source: ArchiveSource, paths: AssetPaths) -> None:
    web, nginx, integration = paths.staging
    for staging in paths.staging:
        remove_path(staging)
    web.mkdir(parents=True)
    nginx.mkdir(parents=True)
    (integration / "utils").mkdir(parents=True)

    try:
        extract_archive(source.archive(HTML_PATH), web)
        extract_archive(source.archive(NGINX_PATH), nginx)
        extract_archive(source.archive(ZIP_CACHE_PATH), integration / "utils")

        replace_required(
            integration / "utils/zip_cache.py",
            ZIP_CACHE_MARKER,
            ZIP_CACHE_REPLACEMENT,
        )
        remove_path(web / "assets/romm/resources")
        (web / "assets/romm").mkdir(parents=True, exist_ok=True)
        publish(paths)
    except (Error, OSError) as error:
        for staging in paths.staging:
            remove_path(staging)
        if isinstance(error, Error):
            raise
        raise Error("failed to prepare RomM integration assets") from error


def parser() -> argparse.ArgumentParser:
    argument_parser = argparse.ArgumentParser(
        description="Prepare RomM web and host integration assets"
    )
    argument_parser.add_argument("--socket-url", required=True)
    argument_parser.add_argument("--image-ref", required=True)
    argument_parser.add_argument("--image-file", type=Path, required=True)
    argument_parser.add_argument("--state-dir", type=Path, required=True)
    return argument_parser


def run(arguments: Sequence[str], stderr: TextIO) -> int:
    options = parser().parse_args(arguments)
    try:
        with PodmanArchiveSource(
            options.socket_url,
            options.image_ref,
            options.image_file,
        ) as source:
            prepare_assets(source, AssetPaths(options.state_dir))
    except Error as error:
        print(f"romm-prepare-assets: {error}", file=stderr)
        return 1
    return 0


def main() -> None:
    raise SystemExit(run(sys.argv[1:], sys.stderr))
