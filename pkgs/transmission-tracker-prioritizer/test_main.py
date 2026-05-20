import unittest

from main import (
    TR_PRI_HIGH,
    TR_PRI_LOW,
    TR_PRI_NORMAL,
    torrent_desired_priority,
)


class TorrentDesiredPriorityTests(unittest.TestCase):
    def test_preferred_torrents_are_always_high(self) -> None:
        desired_priority = torrent_desired_priority(
            torrent={"uploadRatio": 99.0},
            is_preferred=True,
            has_any_preferred_torrents=True,
            non_preferred_low_priority_ratio_threshold=3.0,
        )

        self.assertEqual(desired_priority, TR_PRI_HIGH)

    def test_non_preferred_under_threshold_stays_normal_when_preferred_exist(
        self,
    ) -> None:
        desired_priority = torrent_desired_priority(
            torrent={"uploadRatio": 2.9},
            is_preferred=False,
            has_any_preferred_torrents=True,
            non_preferred_low_priority_ratio_threshold=3.0,
        )

        self.assertEqual(desired_priority, TR_PRI_NORMAL)

    def test_non_preferred_at_threshold_is_low_when_preferred_exist(self) -> None:
        desired_priority = torrent_desired_priority(
            torrent={"uploadRatio": 3.0},
            is_preferred=False,
            has_any_preferred_torrents=True,
            non_preferred_low_priority_ratio_threshold=3.0,
        )

        self.assertEqual(desired_priority, TR_PRI_LOW)

    def test_non_preferred_under_threshold_becomes_high_without_preferred(self) -> None:
        desired_priority = torrent_desired_priority(
            torrent={"uploadRatio": 2.9},
            is_preferred=False,
            has_any_preferred_torrents=False,
            non_preferred_low_priority_ratio_threshold=3.0,
        )

        self.assertEqual(desired_priority, TR_PRI_HIGH)

    def test_non_preferred_at_threshold_stays_low_without_preferred(self) -> None:
        desired_priority = torrent_desired_priority(
            torrent={"uploadRatio": 3.0},
            is_preferred=False,
            has_any_preferred_torrents=False,
            non_preferred_low_priority_ratio_threshold=3.0,
        )

        self.assertEqual(desired_priority, TR_PRI_LOW)


if __name__ == "__main__":
    unittest.main()
