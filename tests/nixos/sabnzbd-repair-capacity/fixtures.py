"""Make incomplete NZBs with real PAR2 volumes whose names overstate capacity."""

import hashlib
import json
import subprocess
import sys
from pathlib import Path

from sabnzbd_test import Segment, make_nzb

BLOCK_SIZE = 256 * 1024
BLOCKS = 16
PROBE_SIZE = 4096


def make_set(directory: Path, name: str, index: int, par2: str) -> Path:
    payload = directory / f"{name}.bin"
    payload.write_bytes(hashlib.shake_256(name.encode()).digest(BLOCKS * BLOCK_SIZE))
    subprocess.run(
        [
            par2,
            "create",
            "-q",
            "-t1",
            f"-s{BLOCK_SIZE}",
            "-c4",
            "-n4",
            str(directory / name),
            str(payload),
        ],
        check=True,
    )

    (directory / f"{name}.par2").rename(directory / f"bundle.vol-0{index + 1}.par2")
    for number, volume in enumerate(sorted(directory.glob(f"{name}.vol*.par2"))):
        # Each file holds one recovery block. Its suffix looks like a much
        # larger block count to SABnzbd's filename heuristic.
        volume.rename(directory / f"bundle.vol-0{100 + index * 4 + number}.par2")

    return payload


def make_job(directory: Path, names: tuple[str, ...], missing: set[int], par2: str) -> dict:
    directory.mkdir()
    articles = {}
    payloads = []
    for index, name in enumerate(names):
        payload = make_set(directory, name, index, par2)
        articles[payload.name] = [
            Segment(number + 1, number * BLOCK_SIZE, BLOCK_SIZE)
            for number in range(BLOCKS)
            if number not in missing
        ]
        payloads.append(payload.name)

    for volume in directory.glob("*.par2"):
        size = volume.stat().st_size
        if size > PROBE_SIZE:
            # SABnzbd can probe the first article without fetching the body.
            # The yEnc header still advertises the full decoded file size.
            articles[volume.name] = [
                Segment(1, 0, PROBE_SIZE),
                Segment(2, PROBE_SIZE, size - PROBE_SIZE),
            ]

    make_nzb(directory, directory.name, articles)
    return {
        "payloads": payloads,
        # Leave ample room for every PAR2 header probe and index file. A
        # recovery body exceeds this allowance on its own.
        "download_budget": len(names) * (BLOCKS - len(missing)) * BLOCK_SIZE + BLOCK_SIZE // 2,
    }


def main() -> None:
    directory = Path(sys.argv[1])
    directory.mkdir()
    par2 = sys.argv[2]
    repairable = make_job(directory / "repairable", ("payload",), {4, 8}, par2)
    # Each set loses twelve blocks, while all eight recovery volumes together
    # contain only eight. Even pooling the sets cannot make repair possible.
    unrepairable = make_job(
        directory / "unrepairable",
        ("first", "second"),
        {number for number in range(BLOCKS) if number % 4},
        par2,
    )
    (directory / "manifest.json").write_text(
        json.dumps({"repairable": repairable, "unrepairable": unrepairable})
    )


if __name__ == "__main__":
    main()
