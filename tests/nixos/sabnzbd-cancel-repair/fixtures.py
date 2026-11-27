"""Make two independently damaged PAR2 sets for SABnzbd's NNTP fixture."""

import hashlib
import subprocess
import sys
from pathlib import Path
from xml.etree import ElementTree


def make_set(directory: Path, name: str, par2: str) -> None:
    data = bytearray(hashlib.shake_256(name.encode()).digest(64 * 1024))
    payload = directory / f"{name}.bin"
    payload.write_bytes(data)
    subprocess.run(
        [par2, "create", "-q", "-t1", "-s4096", "-c1", str(directory / name), str(payload)],
        check=True,
    )

    # Damage two blocks after creating one block of recovery data. The article
    # checksums remain valid, but quick-check cannot skip PAR2 verification.
    data[0] ^= 1
    data[4096] ^= 1
    payload.write_bytes(data)


def make_nzb(directory: Path) -> None:
    root = ElementTree.Element("nzb", xmlns="http://www.newzbin.com/DTD/2003/nzb")
    for path in sorted(directory.iterdir()):
        size = path.stat().st_size
        entry = ElementTree.SubElement(
            root,
            "file",
            poster="test@example.invalid",
            date="1700000000",
            subject=f'"{path.name}" yEnc (1/1)',
        )
        groups = ElementTree.SubElement(entry, "groups")
        ElementTree.SubElement(groups, "group").text = "alt.binaries.test"
        segments = ElementTree.SubElement(entry, "segments")
        ElementTree.SubElement(
            segments, "segment", number="1", bytes=str(size)
        ).text = f"file={path}|part=1|start=0|size={size}"

    ElementTree.ElementTree(root).write(
        directory / "multi-set.nzb", encoding="utf-8", xml_declaration=True
    )


def main() -> None:
    directory = Path(sys.argv[1])
    directory.mkdir()
    for name in ("first", "second"):
        make_set(directory, name, sys.argv[2])
    make_nzb(directory)


if __name__ == "__main__":
    main()
