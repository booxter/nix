import argparse
import json
import tempfile
import unittest
from pathlib import Path

from main import (
    expected_tag,
    find_user_tag,
    read_api_key,
    sanitize_display_name,
    service_base_url,
    update_user_tags,
)


class FakeClient:
    def __init__(self):
        self.mutations = []
        self.requests = [
            {
                "id": 1,
                "status": 2,
                "type": "movie",
                "serverId": 0,
                "is4k": False,
                "requestedBy": {"id": 7, "displayName": "Éve  User!"},
                "media": {"tmdbId": 101},
            },
            {
                "id": 2,
                "status": 5,
                "type": "tv",
                "serverId": 0,
                "is4k": False,
                "requestedBy": {"id": 8, "displayName": "Sam"},
                "media": {"tvdbId": 202},
            },
            {
                "id": 3,
                "status": 3,
                "type": "movie",
                "serverId": 0,
                "is4k": False,
                "requestedBy": {"id": 9, "displayName": "Declined"},
                "media": {"tmdbId": 303},
            },
        ]
        self.tags = {"radarr": [], "sonarr": [{"id": 20, "label": "8-Sam"}]}

    def request(self, base_url, path, api_key, *, method="GET", body=None, query=None):
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
        kind = "radarr" if "/radarr/" in base_url else "sonarr"
        if path == "/tag" and method == "GET":
            return list(self.tags[kind])
        if path == "/movie":
            return [{"id": 11, "title": "Movie", "tmdbId": 101, "tags": []}]
        if path == "/series":
            return [{"id": 22, "title": "Series", "tvdbId": 202, "tags": []}]
        if path == "/tag" and method == "POST":
            tag = {"id": 10, "label": body["label"]}
            self.tags[kind].append(tag)
            self.mutations.append((method, path, body))
            return tag
        if path in {"/movie/editor", "/series/editor"} and method == "PUT":
            self.mutations.append((method, path, body))
            return None
        raise AssertionError((base_url, path, method, body, query))

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
            "tagRequests": True,
        }


def args(api_key_file, *, apply=False):
    return argparse.Namespace(
        api_key_file=str(api_key_file),
        apply=apply,
        batch_size=500,
        page_size=1,
        seerr_url="http://seerr",
        timeout=1,
        user=[],
        verbose=False,
    )


class SeerrUpdateUserTagsTests(unittest.TestCase):
    def test_matches_seerr_tag_sanitization(self):
        self.assertEqual(sanitize_display_name(" Éve  User! "), "Eve-User")
        self.assertEqual(
            expected_tag({"id": 7, "displayName": " Éve  User! "}), "7-Eve-User"
        )

    def test_finds_current_and_legacy_tags_by_user_id(self):
        tags = [
            {"id": 1, "label": "12-Someone"},
            {"id": 2, "label": "1 - Legacy"},
        ]
        self.assertEqual(find_user_tag(tags, 1)["id"], 2)
        self.assertIsNone(find_user_tag(tags, 2))

    def test_builds_service_url_with_base_path(self):
        service = {
            "hostname": "sonarr",
            "port": 8989,
            "useSsl": False,
            "baseUrl": "/sonarr/",
        }
        self.assertEqual(service_base_url(service), "http://sonarr:8989/sonarr/api/v3")

    def test_reads_api_key_from_seerr_settings(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "settings.json"
            path.write_text(json.dumps({"main": {"apiKey": "secret"}}))
            self.assertEqual(read_api_key(path), "secret")

    def test_dry_run_is_read_only_and_paginates(self):
        with tempfile.TemporaryDirectory() as directory:
            key_file = Path(directory) / "key"
            key_file.write_text("secret")
            client = FakeClient()
            output = []
            stats = update_user_tags(
                args(key_file), client=client, output=output.append
            )
        self.assertEqual(client.mutations, [])
        self.assertEqual(stats["requests"], 3)
        self.assertEqual(stats["eligible_requests"], 2)
        self.assertEqual(stats["unique_attributions"], 2)
        self.assertEqual(stats["items_to_update"], 2)
        self.assertIn("  WOULD CREATE tag 7-Eve-User", output)

    def test_apply_uses_bulk_tag_add_endpoints(self):
        with tempfile.TemporaryDirectory() as directory:
            key_file = Path(directory) / "key"
            key_file.write_text("secret")
            client = FakeClient()
            output = []
            stats = update_user_tags(
                args(key_file, apply=True), client=client, output=output.append
            )
        self.assertEqual(stats["items_to_update"], 2)
        self.assertIn(("POST", "/tag", {"label": "7-Eve-User"}), client.mutations)
        self.assertIn(
            (
                "PUT",
                "/movie/editor",
                {"movieIds": [11], "tags": [10], "applyTags": "add"},
            ),
            client.mutations,
        )
        self.assertIn(
            (
                "PUT",
                "/series/editor",
                {"seriesIds": [22], "tags": [20], "applyTags": "add"},
            ),
            client.mutations,
        )


if __name__ == "__main__":
    unittest.main()
