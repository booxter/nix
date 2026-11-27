"""API and NNTP fixture helpers shared by SABnzbd's VM tests."""

import json
import time
from dataclasses import dataclass
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


def download(nzb: Path):
    added = api("addlocalfile", name=str(nzb), pp=1)
    assert added["status"], added
    job_id = added["nzo_ids"][0]

    def finished():
        snapshot = api("history", nzo_ids=job_id)["history"]
        slot = next(iter(snapshot["slots"]), None)
        if slot and slot["status"] in ("Completed", "Failed") and snapshot["ppslots"] == 0:
            return slot
        return None

    return wait_for(finished, f"{nzb.stem} to finish", timeout=60)


@dataclass(frozen=True)
class Segment:
    number: int
    start: int
    size: int


def make_nzb(directory: Path, name: str, articles: dict[str, list[Segment]] | None = None) -> None:
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
        file_articles = (
            articles[path.name]
            if articles is not None and path.name in articles
            else [Segment(1, 0, size)]
        )
        for article in file_articles:
            ElementTree.SubElement(
                segments,
                "segment",
                number=str(article.number),
                bytes=str(article.size),
            ).text = f"file={path}|part={article.number}|start={article.start}|size={article.size}"

    ElementTree.ElementTree(root).write(
        directory / f"{name}.nzb", encoding="utf-8", xml_declaration=True
    )
