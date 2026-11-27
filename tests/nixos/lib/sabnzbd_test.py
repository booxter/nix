"""API and NNTP fixture helpers shared by SABnzbd's VM tests."""

import json
import time
from pathlib import Path
from urllib.parse import urlencode
from urllib.request import urlopen
from xml.etree import ElementTree


def api(mode: str, **parameters):
    query = urlencode(
        {
            "mode": mode,
            "apikey": "0123456789abcdef0123456789abcdef",
            "output": "json",
            **parameters,
        }
    )
    with urlopen(f"http://127.0.0.1:8080/api?{query}", timeout=10) as response:
        return json.load(response)


def wait_for(predicate, description: str, timeout: int = 30):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = predicate()
        if result:
            return result
        time.sleep(0.1)
    raise AssertionError(f"Timed out waiting for {description}")


def history(job_id: str):
    return next(
        (slot for slot in api("history")["history"]["slots"] if slot["nzo_id"] == job_id),
        None,
    )


def make_nzb(directory: Path, name: str) -> None:
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
        directory / f"{name}.nzb", encoding="utf-8", xml_declaration=True
    )
