import os
from pathlib import Path

from atomic_file_writes import write_text_atomic


def test_creates_parent_and_file_with_explicit_mode(tmp_path: Path) -> None:
    path = tmp_path / "nested" / "state.txt"

    write_text_atomic(path, "hello\n", mode=0o640)

    assert path.read_text() == "hello\n"
    assert path.stat().st_mode & 0o777 == 0o640
    assert list(path.parent.iterdir()) == [path]


def test_replaces_existing_content_and_mode(tmp_path: Path) -> None:
    path = tmp_path / "state.txt"
    path.write_text("old")
    path.chmod(0o644)

    write_text_atomic(path, "new", mode=0o600)

    assert path.read_text() == "new"
    assert path.stat().st_mode & 0o777 == 0o600


def test_sets_explicit_owner_before_replacement(tmp_path: Path) -> None:
    path = tmp_path / "state.txt"

    write_text_atomic(path, "owned", uid=os.getuid(), gid=os.getgid())

    stat = path.stat()
    assert stat.st_uid == os.getuid()
    assert stat.st_gid == os.getgid()
