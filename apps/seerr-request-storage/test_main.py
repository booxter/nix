import argparse
import tempfile
import unittest
from pathlib import Path

from main import build_report, format_bytes, render_table


class FakeClient:
    def __init__(self):
        user_one = {"id": 1, "displayName": "One"}
        user_two = {"id": 2, "displayName": "Two"}
        self.requests = [
            self._movie_request(1, 101, user_one),
            self._movie_request(2, 101, user_two),
            self._movie_request(3, 102, user_one),
            self._movie_request(4, 102, user_one),
            {
                "id": 5,
                "status": 5,
                "type": "tv",
                "serverId": 0,
                "is4k": False,
                "requestedBy": user_two,
                "media": {"tvdbId": 201},
                "seasons": [{"seasonNumber": 1}],
            },
            self._movie_request(6, 999, user_two, status=3),
        ]

    @staticmethod
    def _movie_request(request_id, tmdb_id, user, status=2):
        return {
            "id": request_id,
            "status": status,
            "type": "movie",
            "serverId": 0,
            "is4k": False,
            "requestedBy": user,
            "media": {"tmdbId": tmdb_id},
        }

    def get(self, base_url, path, api_key, *, query=None):
        if path == "/api/v1/settings/radarr":
            return [self._service("radarr")]
        if path == "/api/v1/settings/sonarr":
            return [self._service("sonarr")]
        if path == "/api/v1/request":
            skip = int(query["skip"])
            take = int(query["take"])
            return {
                "pageInfo": {"results": len(self.requests)},
                "results": self.requests[skip : skip + take],
            }
        if path == "/movie":
            return [
                {
                    "id": 11,
                    "tmdbId": 101,
                    "sizeOnDisk": 100,
                    "movieFile": {"id": 111},
                },
                {
                    "id": 12,
                    "tmdbId": 102,
                    "sizeOnDisk": 300,
                    "movieFile": {"id": 112},
                },
            ]
        if path == "/series":
            return [{"id": 21, "tvdbId": 201}]
        if path == "/episodefile":
            self.assert_query(query, {"seriesId": 21})
            return [{"id": 211, "seasonNumber": 1, "size": 200}]
        raise AssertionError((base_url, path, api_key, query))

    @staticmethod
    def assert_query(actual, expected):
        if actual != expected:
            raise AssertionError((actual, expected))

    @staticmethod
    def _service(kind):
        return {
            "id": 0,
            "name": kind,
            "hostname": "127.0.0.1",
            "port": 1234,
            "baseUrl": f"/{kind}",
            "useSsl": False,
            "apiKey": f"{kind}-key",
        }


def args(api_key_file):
    return argparse.Namespace(
        api_key_file=str(api_key_file),
        page_size=2,
        seerr_url="http://seerr",
        timeout=1,
    )


class SeerrRequestStorageTests(unittest.TestCase):
    def test_attributes_shared_and_exclusive_storage(self):
        with tempfile.TemporaryDirectory() as directory:
            key_file = Path(directory) / "key"
            key_file.write_text("secret")
            report = build_report(args(key_file), client=FakeClient())

        rows = {row["userId"]: row for row in report["users"]}
        self.assertEqual(rows[1]["logicalBytes"], 400)
        self.assertEqual(rows[1]["movieBytes"], 400)
        self.assertEqual(rows[1]["tvBytes"], 0)
        self.assertEqual(rows[1]["allocatedBytes"], 350)
        self.assertAlmostEqual(rows[1]["allocatedPercent"], 58.3333)
        self.assertEqual(rows[1]["exclusiveBytes"], 300)
        self.assertEqual(rows[1]["movies"], 2)
        self.assertEqual(rows[2]["logicalBytes"], 300)
        self.assertEqual(rows[2]["movieBytes"], 100)
        self.assertEqual(rows[2]["tvBytes"], 200)
        self.assertEqual(rows[2]["allocatedBytes"], 250)
        self.assertEqual(rows[2]["exclusiveBytes"], 200)
        self.assertEqual(rows[2]["series"], 1)
        self.assertEqual(rows[2]["seasons"], 1)
        self.assertEqual(report["totals"]["distinctBytes"], 600)
        self.assertEqual(report["totals"]["movieBytes"], 400)
        self.assertEqual(report["totals"]["tvBytes"], 200)
        self.assertEqual(report["totals"]["logicalBytes"], 700)
        self.assertEqual(report["totals"]["sharedFiles"], 1)
        self.assertEqual(
            report["requests"], {"scanned": 6, "eligible": 5, "skipped": 1}
        )

    def test_renders_human_readable_report(self):
        report = {
            "users": [
                {
                    "userId": 1,
                    "displayName": "One",
                    "movies": 1,
                    "series": 0,
                    "seasons": 0,
                    "files": 1,
                    "movieBytes": 1024**4,
                    "tvBytes": 0,
                    "logicalBytes": 1024**4,
                    "allocatedBytes": 1024**4,
                    "allocatedPercent": 100.0,
                    "exclusiveBytes": 1024**4,
                }
            ],
            "totals": {
                "distinctBytes": 1024**4,
                "movieBytes": 1024**4,
                "tvBytes": 0,
                "logicalBytes": 1024**4,
                "files": 1,
                "sharedFiles": 0,
            },
            "unresolved": {
                "moviesNotInRadarr": 0,
                "moviesWithoutFiles": 0,
                "seriesNotInSonarr": 0,
                "seasonsWithoutFiles": 0,
            },
            "requests": {"scanned": 1, "eligible": 1, "skipped": 0},
        }
        output = render_table(report)
        self.assertIn("1.0 TiB", output)
        self.assertIn("Distinct attributed storage", output)
        self.assertEqual(format_bytes(1024**3), "1.0 GiB")


if __name__ == "__main__":
    unittest.main()
