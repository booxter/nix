from __future__ import annotations

import io
import tarfile
from collections.abc import Iterable, Mapping
from dataclasses import dataclass
from pathlib import Path

import pytest

from romm_tools.assets import (
    HTML_PATH,
    NGINX_PATH,
    ZIP_CACHE_PATH,
    AssetPaths,
    Error,
    PodmanArchiveSource,
    prepare_assets,
    publish,
    run,
)


def archive_bytes(files: Mapping[str, bytes], links: Mapping[str, str] | None = None) -> bytes:
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode="w") as archive:
        for name, contents in files.items():
            info = tarfile.TarInfo(name)
            info.size = len(contents)
            info.mode = 0o644
            archive.addfile(info, io.BytesIO(contents))
        for name, target in (links or {}).items():
            info = tarfile.TarInfo(name)
            info.type = tarfile.SYMTYPE
            info.linkname = target
            archive.addfile(info)
    return output.getvalue()


@dataclass(frozen=True)
class TarArchiveSource:
    archives: Mapping[str, bytes]

    def archive(self, path: str) -> Iterable[bytes]:
        contents = self.archives[path]
        midpoint = len(contents) // 2
        return (contents[:midpoint], contents[midpoint:])


def source(*, valid_index: bool = True) -> TarArchiveSource:
    index = b"<html><head></head><body>RomM</body></html>"
    if not valid_index:
        index = b"<html>changed upstream</html>"
    return TarArchiveSource(
        {
            HTML_PATH: archive_bytes(
                {
                    "index.html": index,
                    "assets/app.js": b"application",
                },
                {"assets/romm/resources": "/romm/resources"},
            ),
            NGINX_PATH: archive_bytes({"decode.js": b"export default {}"}),
            ZIP_CACHE_PATH: archive_bytes(
                {"zip_cache.py": b"before\n        os.rename(tmp_path, target)\nafter\n"}
            ),
        }
    )


def create_current(paths: AssetPaths) -> None:
    for directory in paths.current:
        directory.mkdir(parents=True)
        (directory / "preserved").write_text(directory.name)


def test_prepares_patches_and_publishes_complete_asset_trees(tmp_path: Path) -> None:
    paths = AssetPaths(tmp_path)
    create_current(paths)
    for previous in paths.previous:
        previous.symlink_to(tmp_path / "stale-missing-tree")

    prepare_assets(source(), paths)

    web, nginx, integration = paths.current
    assert not (web / "assets/romm/resources").exists()
    assert (web / "assets/app.js").read_text() == "application"
    assert (nginx / "decode.js").read_text() == "export default {}"
    zip_cache = (integration / "utils/zip_cache.py").read_text()
    assert "os.chmod(tmp_path, 0o640)" in zip_cache
    assert "os.rename(tmp_path, target)" in zip_cache
    assert all(
        not path.exists() and not path.is_symlink() for path in (*paths.staging, *paths.previous)
    )


def test_publication_failure_restores_every_previous_tree(tmp_path: Path) -> None:
    paths = AssetPaths(tmp_path)
    create_current(paths)
    for staging in paths.staging[:2]:
        staging.mkdir()
        (staging / "replacement").write_text(staging.name)

    with pytest.raises(Error, match="failed to publish"):
        publish(paths)

    for current in paths.current:
        assert (current / "preserved").read_text() == current.name
    assert all(not path.exists() for path in paths.previous)


def test_path_traversal_archive_is_rejected_without_publication(tmp_path: Path) -> None:
    paths = AssetPaths(tmp_path)
    create_current(paths)
    malicious = source()
    archives = dict(malicious.archives)
    archives[NGINX_PATH] = archive_bytes({"../escaped": b"bad"})

    try:
        prepare_assets(TarArchiveSource(archives), paths)
    except (RuntimeError, tarfile.TarError):
        pass
    else:
        raise AssertionError("unsafe archive member was accepted")

    assert not (tmp_path.parent / "escaped").exists()
    for current in paths.current:
        assert (current / "preserved").exists()


def test_unavailable_podman_socket_reports_clean_error(tmp_path: Path) -> None:
    image = tmp_path / "image.tar"
    image.write_bytes(b"not-read-without-a-socket")
    stderr = io.StringIO()

    status = run(
        [
            "--socket-url",
            f"http+unix://{tmp_path}/missing.sock",
            "--image-ref",
            "example.invalid/romm:test",
            "--image-file",
            str(image),
            "--state-dir",
            str(tmp_path / "state"),
        ],
        stderr,
    )

    assert status == 1
    assert "failed to create" in stderr.getvalue()


def test_closed_podman_source_cannot_return_archives(tmp_path: Path) -> None:
    source = PodmanArchiveSource(
        f"http+unix://{tmp_path}/missing.sock",
        "example.invalid/romm:test",
        tmp_path / "image.tar",
    )

    with pytest.raises(Error, match="not open"):
        source.archive(HTML_PATH)
