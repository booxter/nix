from pathlib import Path
import tempfile
import unittest

from main import (
    TR_PRI_HIGH,
    TR_PRI_LOW,
    TR_PRI_NORMAL,
    collect_iteration_state,
    torrent_desired_priority,
)


class TorrentDesiredPriorityTests(unittest.TestCase):
    def test_preferred_torrents_are_always_high(self) -> None:
        desired_priority = torrent_desired_priority(
            torrent={"uploadRatio": 99.0},
            is_preferred=True,
            preferred_bootstrap_active=True,
            non_preferred_low_priority_ratio_threshold=3.0,
        )

        self.assertEqual(desired_priority, TR_PRI_HIGH)

    def test_non_preferred_under_threshold_stays_normal_when_preferred_have_peers(
        self,
    ) -> None:
        desired_priority = torrent_desired_priority(
            torrent={"uploadRatio": 2.9},
            is_preferred=False,
            preferred_bootstrap_active=True,
            non_preferred_low_priority_ratio_threshold=3.0,
        )

        self.assertEqual(desired_priority, TR_PRI_NORMAL)

    def test_non_preferred_at_threshold_is_low_when_preferred_have_peers(self) -> None:
        desired_priority = torrent_desired_priority(
            torrent={"uploadRatio": 3.0},
            is_preferred=False,
            preferred_bootstrap_active=True,
            non_preferred_low_priority_ratio_threshold=3.0,
        )

        self.assertEqual(desired_priority, TR_PRI_LOW)

    def test_non_preferred_under_threshold_becomes_high_without_active_preferred_peers(
        self,
    ) -> None:
        desired_priority = torrent_desired_priority(
            torrent={"uploadRatio": 2.9},
            is_preferred=False,
            preferred_bootstrap_active=False,
            non_preferred_low_priority_ratio_threshold=3.0,
        )

        self.assertEqual(desired_priority, TR_PRI_HIGH)

    def test_non_preferred_at_threshold_stays_low_without_active_preferred_peers(
        self,
    ) -> None:
        desired_priority = torrent_desired_priority(
            torrent={"uploadRatio": 3.0},
            is_preferred=False,
            preferred_bootstrap_active=False,
            non_preferred_low_priority_ratio_threshold=3.0,
        )

        self.assertEqual(desired_priority, TR_PRI_LOW)


class FakeClient:
    def __init__(self, torrents: list[dict]) -> None:
        self.torrents = torrents

    def call(self, method: str, arguments: dict | None = None) -> dict:
        self.last_call = (method, arguments)
        if method != "torrent-get":
            raise AssertionError(f"unexpected RPC method {method!r}")
        return {"torrents": self.torrents}


class CollectIterationStateTests(unittest.TestCase):
    def test_non_preferred_under_threshold_is_promoted_when_preferred_has_no_peers(
        self,
    ) -> None:
        torrents = [
            {
                "hashString": "preferred",
                "bandwidthPriority": TR_PRI_HIGH,
                "uploadRatio": 0.1,
                "peersConnected": 0,
                "peersGettingFromUs": 0,
                "peersSendingToUs": 0,
                "leftUntilDone": 0,
                "rateDownload": 0,
                "rateUpload": 0,
                "trackerStats": [{"host": "preferred.example"}],
            },
            {
                "hashString": "public",
                "bandwidthPriority": TR_PRI_NORMAL,
                "uploadRatio": 2.9,
                "peersConnected": 0,
                "peersGettingFromUs": 0,
                "peersSendingToUs": 0,
                "leftUntilDone": 0,
                "rateDownload": 0,
                "rateUpload": 0,
                "trackerStats": [{"host": "public.example"}],
            },
        ]

        state = self.collect_state(torrents)

        self.assertFalse(state.preferred_bootstrap_active)
        self.assertEqual(state.high_priority_hashes, ["public"])
        self.assertEqual(state.normal_priority_hashes, [])

    def test_non_preferred_under_threshold_is_lowered_when_preferred_has_peers(
        self,
    ) -> None:
        torrents = [
            {
                "hashString": "preferred",
                "bandwidthPriority": TR_PRI_HIGH,
                "uploadRatio": 0.1,
                "peersConnected": 1,
                "peersGettingFromUs": 0,
                "peersSendingToUs": 0,
                "leftUntilDone": 0,
                "rateDownload": 0,
                "rateUpload": 0,
                "trackerStats": [{"host": "preferred.example"}],
            },
            {
                "hashString": "public",
                "bandwidthPriority": TR_PRI_HIGH,
                "uploadRatio": 2.9,
                "peersConnected": 0,
                "peersGettingFromUs": 0,
                "peersSendingToUs": 0,
                "leftUntilDone": 0,
                "rateDownload": 0,
                "rateUpload": 0,
                "trackerStats": [{"host": "public.example"}],
            },
        ]

        state = self.collect_state(torrents)

        self.assertTrue(state.preferred_bootstrap_active)
        self.assertEqual(state.high_priority_hashes, [])
        self.assertEqual(state.normal_priority_hashes, ["public"])

    def collect_state(self, torrents: list[dict]):
        with tempfile.TemporaryDirectory() as tmp_dir:
            trackers_file = Path(tmp_dir) / "trackers.txt"
            trackers_file.write_text("preferred.example\n", encoding="utf-8")
            _status, state = collect_iteration_state(
                client=FakeClient(torrents),
                trackers_file=trackers_file,
                last_tracker_status=None,
                non_preferred_low_priority_ratio_threshold=3.0,
            )

        if state is None:
            self.fail("expected iteration state")
        return state


if __name__ == "__main__":
    unittest.main()
