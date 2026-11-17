"""Local Prowlarr/Torznab fixture advertising torrents served by the test seeder."""

import json
import xml.etree.ElementTree as ET
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit


def releases() -> bytes:
    rss = ET.Element("rss", version="2.0")
    channel = ET.SubElement(rss, "channel")
    for suffix, category in (("epub", "7020"), ("m4b", "3030")):
        item = ET.SubElement(channel, "item")
        ET.SubElement(item, "title").text = f"Reflink test {suffix}"
        ET.SubElement(item, "guid").text = f"reflink-{suffix}"
        url = f"http://server:9000/source.{suffix}.torrent"
        ET.SubElement(item, "link").text = url
        ET.SubElement(item, "enclosure", url=url, length="1048699", type="application/x-bittorrent")
        for name, value in (("category", category), ("seeders", "1"), ("size", "1048699")):
            ET.SubElement(
                item, "{http://torznab.com/schemas/2015/feed}attr", name=name, value=value
            )
    return ET.tostring(rss, encoding="utf-8", xml_declaration=True)


class Indexer(SimpleHTTPRequestHandler):
    def do_GET(self) -> None:
        path = urlsplit(self.path).path
        match path:
            case "/api/v1/indexer":
                body = json.dumps(
                    [
                        {
                            "id": 1,
                            "name": "Local test indexer",
                            "enable": True,
                            "protocol": "torrent",
                            "capabilities": {"categories": [{"id": 7000}, {"id": 3030}]},
                        }
                    ]
                ).encode()
                content_type = "application/json"
            case "/api/v1/indexerstatus":
                body = b"[]"
                content_type = "application/json"
            case "/api/v1/indexer/1/newznab":
                body = releases()
                content_type = "application/rss+xml"
            case _:
                super().do_GET()
                return

        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


if __name__ == "__main__":
    # The other VM reaches this fixture over the isolated test VLAN.
    ThreadingHTTPServer(("0.0.0.0", 9000), Indexer).serve_forever()  # noqa: S104
