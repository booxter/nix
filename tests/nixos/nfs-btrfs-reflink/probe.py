"""Guest-side operations for the NFS/Btrfs integration test."""

import argparse
import json
import os
import shutil
from pathlib import Path


def seed_library(root: Path) -> None:
    (root / "library.bin").write_bytes(b"library")


def seed_releases(root: Path) -> None:
    root.mkdir(parents=True, exist_ok=True)
    for suffix in ("epub", "m4b"):
        (root / f"source.{suffix}").write_bytes(os.urandom(1048699))


def seed_torrent(root: Path) -> None:
    source = root / "torrents/source.bin"
    source.write_bytes(os.urandom(1048699))
    with source.open("rb") as stream:
        os.fsync(stream.fileno())

    # Each subvolume starts its own inode namespace. Exercise the collision
    # that made Python reject different files as identical on a single export.
    assert source.stat().st_ino == (root / "library.bin").stat().st_ino


def check_identity(root: Path) -> None:
    library = root / "library.bin"
    torrent = root / "torrents/source.bin"
    identities = [(path.stat().st_dev, path.stat().st_ino) for path in (library, torrent)]
    print(json.dumps(identities))

    assert not library.samefile(torrent), identities
    assert identities[0][0] != identities[1][0], identities


def copy_and_verify(root: Path, name: str) -> None:
    source = root / "torrents/source.bin"
    destination = root / f"{name}.bin"
    shutil.copy2(source, destination)
    with destination.open("rb") as stream:
        os.fsync(stream.fileno())

    assert source.read_bytes() == destination.read_bytes()


def check_independent_write(root: Path, name: str) -> None:
    source = root / "torrents/source.bin"
    destination = root / f"{name}.bin"
    before = source.read_bytes()
    with destination.open("r+b") as stream:
        stream.write(b"changed")

    assert source.read_bytes() == before
    assert destination.read_bytes() != before


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    actions = parser.add_subparsers(dest="action", required=True)
    for action in ("seed-library", "seed-torrent", "seed-releases", "identity"):
        actions.add_parser(action)
    for action in ("copy", "independent-write"):
        actions.add_parser(action).add_argument("name")
    args = parser.parse_args()

    match args.action:
        case "seed-library":
            seed_library(args.root)
        case "seed-releases":
            seed_releases(args.root)
        case "seed-torrent":
            seed_torrent(args.root)
        case "identity":
            check_identity(args.root)
        case "copy":
            copy_and_verify(args.root, args.name)
        case "independent-write":
            check_independent_write(args.root, args.name)


if __name__ == "__main__":
    main()
