import json
from email.message import Message
from pathlib import Path
import tempfile
import unittest
import urllib.error
from unittest.mock import patch

from transmission_common.transmission import (
    TransmissionRpcClient,
    TransmissionRpcError,
    normalize_tracker_host,
    read_tracker_hosts,
    torrent_matches_tracker_hosts,
)


class FakeResponse:
    def __init__(self, payload: dict) -> None:
        self.body = json.dumps(payload).encode("utf-8")

    def __enter__(self) -> "FakeResponse":
        return self

    def __exit__(self, _exc_type: object, _exc: object, _traceback: object) -> None:
        return None

    def read(self) -> bytes:
        return self.body


class TransmissionRpcClientTests(unittest.TestCase):
    def test_call_uses_json_rpc_2_params_and_snake_case(self) -> None:
        requests = []

        def fake_urlopen(request: object, timeout: float) -> FakeResponse:
            requests.append(request)
            return FakeResponse({"jsonrpc": "2.0", "id": 1, "result": {"ok": True}})

        client = TransmissionRpcClient(
            "http://127.0.0.1:9091/transmission/rpc",
            timeout_seconds=20.0,
        )
        with patch("urllib.request.urlopen", side_effect=fake_urlopen):
            result = client.call(
                "torrent_remove",
                {
                    "delete_local_data": True,
                    "hash_string": "abc123",
                },
            )

        self.assertEqual(result, {"ok": True})
        self.assertEqual(len(requests), 1)
        sent = json.loads(requests[0].data.decode("utf-8"))
        self.assertEqual(
            sent,
            {
                "jsonrpc": "2.0",
                "method": "torrent_remove",
                "params": {
                    "delete_local_data": True,
                    "hash_string": "abc123",
                },
                "id": 1,
            },
        )
        self.assertNotIn("arguments", sent)
        self.assertNotIn("delete-local-data", json.dumps(sent))

    def test_call_retries_after_transmission_session_id_challenge(self) -> None:
        requests = []
        headers = Message()
        headers["X-Transmission-Session-Id"] = "session-token"

        def fake_urlopen(request: object, timeout: float) -> FakeResponse:
            requests.append(request)
            if len(requests) == 1:
                raise urllib.error.HTTPError(
                    url="http://127.0.0.1:9091/transmission/rpc",
                    code=409,
                    msg="Conflict",
                    hdrs=headers,
                    fp=None,
                )
            return FakeResponse({"jsonrpc": "2.0", "id": 1, "result": {}})

        client = TransmissionRpcClient(
            "http://127.0.0.1:9091/transmission/rpc",
            timeout_seconds=20.0,
        )
        with patch("urllib.request.urlopen", side_effect=fake_urlopen):
            client.call("session_get")

        self.assertEqual(len(requests), 2)
        self.assertEqual(client.session_id, "session-token")

    def test_call_rejects_json_rpc_error(self) -> None:
        def fake_urlopen(request: object, timeout: float) -> FakeResponse:
            return FakeResponse(
                {
                    "jsonrpc": "2.0",
                    "id": 1,
                    "error": {
                        "code": 3,
                        "message": "method failed",
                        "data": {"error_string": "bad field"},
                    },
                }
            )

        client = TransmissionRpcClient(
            "http://127.0.0.1:9091/transmission/rpc",
            timeout_seconds=20.0,
        )
        with patch("urllib.request.urlopen", side_effect=fake_urlopen):
            with self.assertRaisesRegex(
                TransmissionRpcError,
                "method failed: bad field",
            ):
                client.call("torrent_set")


class TrackerHostTests(unittest.TestCase):
    def test_normalize_tracker_host_accepts_urls_bare_hosts_and_ipv6(self) -> None:
        self.assertEqual(
            normalize_tracker_host("https://Tracker.EXAMPLE:443/announce"),
            "tracker.example",
        )
        self.assertEqual(
            normalize_tracker_host("user:pass@tracker.example:6969/path"),
            "tracker.example",
        )
        self.assertEqual(normalize_tracker_host("[2001:db8::1]:443"), "2001:db8::1")

    def test_read_tracker_hosts_strips_comments_and_reports_empty_entries(self) -> None:
        empty_lines: list[int] = []
        with tempfile.TemporaryDirectory() as tmp_dir:
            trackers_file = Path(tmp_dir) / "trackers.txt"
            trackers_file.write_text(
                "\n".join(
                    [
                        "https://Tracker.EXAMPLE:443/announce",
                        "user:pass@tracker2.example:6969/path # comment",
                        "http:///missing-host",
                        "[2001:db8::1]:443",
                        "",
                    ]
                ),
                encoding="utf-8",
            )

            hosts = read_tracker_hosts(trackers_file, on_empty_entry=empty_lines.append)

        self.assertEqual(
            hosts,
            {
                "tracker.example",
                "tracker2.example",
                "2001:db8::1",
            },
        )
        self.assertEqual(empty_lines, [3])

    def test_torrent_matches_tracker_hosts_from_host_or_announce(self) -> None:
        tracker_hosts = {"preferred.example", "announce.example"}

        self.assertTrue(
            torrent_matches_tracker_hosts(
                {"tracker_stats": [{"host": "preferred.example"}]},
                tracker_hosts,
            )
        )
        self.assertTrue(
            torrent_matches_tracker_hosts(
                {"tracker_stats": [{"announce": "https://announce.example/announce"}]},
                tracker_hosts,
            )
        )
        self.assertFalse(
            torrent_matches_tracker_hosts(
                {"tracker_stats": [{"host": "public.example"}]},
                tracker_hosts,
            )
        )


if __name__ == "__main__":
    unittest.main()
