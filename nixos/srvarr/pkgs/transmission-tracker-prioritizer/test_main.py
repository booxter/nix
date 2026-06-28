from pathlib import Path
import tempfile
import unittest

from main import (
    TR_PRI_HIGH,
    TR_PRI_LOW,
    TR_PRI_NORMAL,
    collect_iteration_state,
    apply_priority_updates,
    torrent_desired_priority,
)


class TorrentDesiredPriorityTests(unittest.TestCase):
    def test_preferred_torrents_are_always_high(self) -> None:
        desired_priority = torrent_desired_priority(
            torrent={"upload_ratio": 99.0},
            is_preferred=True,
            preferred_bootstrap_active=True,
            non_preferred_low_priority_ratio_threshold=3.0,
        )

        self.assertEqual(desired_priority, TR_PRI_HIGH)

    def test_non_preferred_under_threshold_stays_normal_when_preferred_have_upload_peers(
        self,
    ) -> None:
        desired_priority = torrent_desired_priority(
            torrent={"upload_ratio": 2.9},
            is_preferred=False,
            preferred_bootstrap_active=True,
            non_preferred_low_priority_ratio_threshold=3.0,
        )

        self.assertEqual(desired_priority, TR_PRI_NORMAL)

    def test_non_preferred_at_threshold_is_low_when_preferred_have_upload_peers(
        self,
    ) -> None:
        desired_priority = torrent_desired_priority(
            torrent={"upload_ratio": 3.0},
            is_preferred=False,
            preferred_bootstrap_active=True,
            non_preferred_low_priority_ratio_threshold=3.0,
        )

        self.assertEqual(desired_priority, TR_PRI_LOW)

    def test_non_preferred_under_threshold_becomes_high_without_active_preferred_peers(
        self,
    ) -> None:
        desired_priority = torrent_desired_priority(
            torrent={"upload_ratio": 2.9},
            is_preferred=False,
            preferred_bootstrap_active=False,
            non_preferred_low_priority_ratio_threshold=3.0,
        )

        self.assertEqual(desired_priority, TR_PRI_HIGH)

    def test_non_preferred_at_threshold_stays_low_without_active_preferred_peers(
        self,
    ) -> None:
        desired_priority = torrent_desired_priority(
            torrent={"upload_ratio": 3.0},
            is_preferred=False,
            preferred_bootstrap_active=False,
            non_preferred_low_priority_ratio_threshold=3.0,
        )

        self.assertEqual(desired_priority, TR_PRI_LOW)


class FakeClient:
    def __init__(self, torrents: list[dict]) -> None:
        self.torrents = torrents
        self.calls: list[tuple[str, dict | None]] = []

    def call(self, method: str, arguments: dict | None = None) -> dict:
        self.calls.append((method, arguments))
        self.last_call = (method, arguments)
        if method != "torrent_get":
            return {}
        return {"torrents": self.torrents}


class CollectIterationStateTests(unittest.TestCase):
    def test_non_preferred_under_threshold_is_promoted_when_preferred_has_no_upload_peers(
        self,
    ) -> None:
        torrents = [
            {
                "hash_string": "preferred",
                "bandwidth_priority": TR_PRI_HIGH,
                "upload_ratio": 0.1,
                "peers_connected": 0,
                "peers_getting_from_us": 0,
                "peers_sending_to_us": 0,
                "left_until_done": 0,
                "status": 6,
                "rate_download": 0,
                "rate_upload": 0,
                "tracker_stats": [{"host": "preferred.example"}],
            },
            {
                "hash_string": "public",
                "bandwidth_priority": TR_PRI_NORMAL,
                "upload_ratio": 2.9,
                "peers_connected": 0,
                "peers_getting_from_us": 0,
                "peers_sending_to_us": 0,
                "left_until_done": 0,
                "status": 6,
                "rate_download": 0,
                "rate_upload": 0,
                "tracker_stats": [{"host": "public.example"}],
            },
        ]

        state = self.collect_state(torrents)

        self.assertFalse(state.preferred_bootstrap_active)
        self.assertEqual(state.high_priority_hashes, ["public"])
        self.assertEqual(state.normal_priority_hashes, [])

    def test_non_preferred_under_threshold_is_promoted_when_preferred_has_only_idle_connected_peers(
        self,
    ) -> None:
        torrents = [
            {
                "hash_string": "preferred",
                "bandwidth_priority": TR_PRI_HIGH,
                "upload_ratio": 0.1,
                "peers_connected": 1,
                "peers_getting_from_us": 0,
                "peers_sending_to_us": 0,
                "left_until_done": 0,
                "status": 6,
                "rate_download": 0,
                "rate_upload": 0,
                "tracker_stats": [{"host": "preferred.example"}],
            },
            {
                "hash_string": "public",
                "bandwidth_priority": TR_PRI_NORMAL,
                "upload_ratio": 2.9,
                "peers_connected": 0,
                "peers_getting_from_us": 0,
                "peers_sending_to_us": 0,
                "left_until_done": 0,
                "status": 6,
                "rate_download": 0,
                "rate_upload": 0,
                "tracker_stats": [{"host": "public.example"}],
            },
        ]

        state = self.collect_state(torrents)

        self.assertFalse(state.preferred_bootstrap_active)
        self.assertFalse(state.preferred_upload_active)
        self.assertEqual(state.high_priority_hashes, ["public"])
        self.assertEqual(state.normal_priority_hashes, [])

    def test_non_preferred_under_threshold_is_lowered_when_preferred_have_upload_peers(
        self,
    ) -> None:
        torrents = [
            {
                "hash_string": "preferred",
                "bandwidth_priority": TR_PRI_HIGH,
                "upload_ratio": 0.1,
                "peers_connected": 1,
                "peers_getting_from_us": 1,
                "peers_sending_to_us": 0,
                "left_until_done": 0,
                "status": 6,
                "rate_download": 0,
                "rate_upload": 0,
                "tracker_stats": [{"host": "preferred.example"}],
            },
            {
                "hash_string": "public",
                "bandwidth_priority": TR_PRI_HIGH,
                "upload_ratio": 2.9,
                "peers_connected": 0,
                "peers_getting_from_us": 0,
                "peers_sending_to_us": 0,
                "left_until_done": 0,
                "status": 6,
                "rate_download": 0,
                "rate_upload": 0,
                "tracker_stats": [{"host": "public.example"}],
            },
        ]

        state = self.collect_state(torrents)

        self.assertTrue(state.preferred_bootstrap_active)
        self.assertTrue(state.preferred_upload_active)
        self.assertEqual(state.high_priority_hashes, [])
        self.assertEqual(state.normal_priority_hashes, ["public"])

    def test_preferred_upload_activity_requires_upload_peers_not_only_rate(
        self,
    ) -> None:
        torrents = [
            {
                "hash_string": "preferred",
                "bandwidth_priority": TR_PRI_HIGH,
                "upload_ratio": 0.1,
                "peers_connected": 1,
                "peers_getting_from_us": 0,
                "peers_sending_to_us": 0,
                "left_until_done": 0,
                "status": 6,
                "rate_download": 0,
                "rate_upload": 12345,
                "tracker_stats": [{"host": "preferred.example"}],
            },
        ]

        state = self.collect_state(torrents)

        self.assertFalse(state.preferred_bootstrap_active)
        self.assertFalse(state.preferred_upload_active)

    def test_complete_non_preferred_at_pause_ratio_is_stopped(self) -> None:
        torrents = [
            {
                "hash_string": "public",
                "bandwidth_priority": TR_PRI_NORMAL,
                "upload_ratio": 6.0,
                "peers_connected": 0,
                "peers_getting_from_us": 0,
                "peers_sending_to_us": 0,
                "left_until_done": 0,
                "status": 6,
                "rate_download": 0,
                "rate_upload": 0,
                "tracker_stats": [{"host": "public.example"}],
            },
        ]

        state = self.collect_state(torrents)

        self.assertEqual(state.low_priority_hashes, ["public"])
        self.assertEqual(state.stop_hashes, ["public"])

    def test_complete_non_preferred_already_stopped_is_not_stopped_again(self) -> None:
        torrents = [
            {
                "hash_string": "public",
                "bandwidth_priority": TR_PRI_LOW,
                "upload_ratio": 6.0,
                "peers_connected": 0,
                "peers_getting_from_us": 0,
                "peers_sending_to_us": 0,
                "left_until_done": 0,
                "status": 0,
                "rate_download": 0,
                "rate_upload": 0,
                "tracker_stats": [{"host": "public.example"}],
            },
        ]

        state = self.collect_state(torrents)

        self.assertEqual(state.stop_hashes, [])

    def test_preferred_torrent_at_pause_ratio_is_not_stopped(self) -> None:
        torrents = [
            {
                "hash_string": "preferred",
                "bandwidth_priority": TR_PRI_HIGH,
                "upload_ratio": 6.0,
                "peers_connected": 0,
                "peers_getting_from_us": 0,
                "peers_sending_to_us": 0,
                "left_until_done": 0,
                "status": 6,
                "rate_download": 0,
                "rate_upload": 0,
                "tracker_stats": [{"host": "preferred.example"}],
            },
        ]

        state = self.collect_state(torrents)

        self.assertEqual(state.stop_hashes, [])

    def collect_state(self, torrents: list[dict]):
        with tempfile.TemporaryDirectory() as tmp_dir:
            trackers_file = Path(tmp_dir) / "trackers.txt"
            trackers_file.write_text("preferred.example\n", encoding="utf-8")
            _status, state = collect_iteration_state(
                client=FakeClient(torrents),
                trackers_file=trackers_file,
                last_tracker_status=None,
                non_preferred_low_priority_ratio_threshold=3.0,
                non_preferred_pause_ratio_threshold=6.0,
            )

        if state is None:
            self.fail("expected iteration state")
        return state


class ApplyPriorityUpdatesTests(unittest.TestCase):
    def test_stop_actions_are_sent_to_transmission(self) -> None:
        client = FakeClient([])
        state = self.build_state(stop_hashes=["public"])

        apply_priority_updates(client, state)

        self.assertEqual(
            client.calls,
            [
                ("torrent_stop", {"ids": ["public"]}),
            ],
        )

    def test_priority_changes_are_applied_before_stop_actions(self) -> None:
        client = FakeClient([])
        state = self.build_state(low_priority_hashes=["public"], stop_hashes=["public"])

        apply_priority_updates(client, state)

        self.assertEqual(
            client.calls,
            [
                (
                    "torrent_set",
                    {"ids": ["public"], "bandwidth_priority": TR_PRI_LOW},
                ),
                ("torrent_stop", {"ids": ["public"]}),
            ],
        )

    def build_state(
        self,
        *,
        high_priority_hashes: list[str] | None = None,
        normal_priority_hashes: list[str] | None = None,
        low_priority_hashes: list[str] | None = None,
        stop_hashes: list[str] | None = None,
    ):
        from main import IterationState

        return IterationState(
            tracker_hosts_count=1,
            preferred_torrent_count=0,
            preferred_bootstrap_active=False,
            preferred_upload_active=False,
            preferred_upload_bytes_per_second=0,
            torrent_counts={"low": 0, "normal": 0, "high": 0},
            torrent_activity_counts={
                "seeding": {"active": 0, "inactive": 0},
                "downloading": {"active": 0, "inactive": 0},
            },
            bandwidth_active_torrent_counts={
                "download": {"low": 0, "normal": 0, "high": 0},
                "upload": {"low": 0, "normal": 0, "high": 0},
            },
            peer_counts={
                "low": {"connected": 0, "getting_from_us": 0, "sending_to_us": 0},
                "normal": {"connected": 0, "getting_from_us": 0, "sending_to_us": 0},
                "high": {"connected": 0, "getting_from_us": 0, "sending_to_us": 0},
            },
            download_bytes_per_second={"low": 0, "normal": 0, "high": 0},
            upload_bytes_per_second={"low": 0, "normal": 0, "high": 0},
            high_priority_hashes=high_priority_hashes or [],
            normal_priority_hashes=normal_priority_hashes or [],
            low_priority_hashes=low_priority_hashes or [],
            stop_hashes=stop_hashes or [],
        )


if __name__ == "__main__":
    unittest.main()
