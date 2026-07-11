import argparse
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from main import TransmissionRpcError, run_once


NOW = 2_000_000_000
DAY_SECONDS = 86400


class RunOnceTests(unittest.TestCase):
    def test_over_age_non_preferred_torrent_is_deleted_even_when_incomplete(
        self,
    ) -> None:
        exit_code, removed = self.run_cleaner(
            [
                self.make_torrent(
                    hash_string="old-public",
                    name="old-public",
                    added_date=NOW - 366 * DAY_SECONDS,
                    left_until_done=1024,
                    percent_done=0.5,
                    done_date=0,
                    status=4,
                    upload_ratio=0.2,
                )
            ]
        )

        self.assertEqual(exit_code, 0)
        self.assertEqual(removed, [(["old-public"], True)])

    def test_over_age_non_preferred_seeding_torrent_below_ratio_is_deleted(
        self,
    ) -> None:
        exit_code, removed = self.run_cleaner(
            [
                self.make_torrent(
                    hash_string="still-seeding",
                    name="still-seeding",
                    added_date=NOW - 366 * DAY_SECONDS,
                    done_date=NOW - 366 * DAY_SECONDS,
                    left_until_done=0,
                    percent_done=1.0,
                    status=6,
                    upload_ratio=0.2,
                )
            ]
        )

        self.assertEqual(exit_code, 0)
        self.assertEqual(removed, [(["still-seeding"], True)])

    def test_under_age_non_preferred_seeding_torrent_below_ratio_is_kept(
        self,
    ) -> None:
        exit_code, removed = self.run_cleaner(
            [
                self.make_torrent(
                    hash_string="young-seeding",
                    name="young-seeding",
                    added_date=NOW - 364 * DAY_SECONDS,
                    done_date=NOW - 364 * DAY_SECONDS,
                    left_until_done=0,
                    percent_done=1.0,
                    status=6,
                    upload_ratio=2.9,
                )
            ]
        )

        self.assertEqual(exit_code, 0)
        self.assertEqual(removed, [])

    def test_over_age_preferred_torrent_is_exempt(self) -> None:
        exit_code, removed = self.run_cleaner(
            [
                self.make_torrent(
                    hash_string="old-preferred",
                    name="old-preferred",
                    added_date=NOW - 366 * DAY_SECONDS,
                    left_until_done=1024,
                    percent_done=0.5,
                    done_date=0,
                    status=4,
                    upload_ratio=0.2,
                    tracker_stats=[{"host": "preferred.example"}],
                )
            ]
        )

        self.assertEqual(exit_code, 0)
        self.assertEqual(removed, [])

    def test_old_complete_high_ratio_torrent_still_matches_existing_rule(self) -> None:
        exit_code, removed = self.run_cleaner(
            [
                self.make_torrent(
                    hash_string="old-high-ratio",
                    name="old-high-ratio",
                    added_date=NOW - 90 * DAY_SECONDS,
                    done_date=NOW - 45 * DAY_SECONDS,
                    left_until_done=0,
                    percent_done=1.0,
                    status=6,
                    upload_ratio=3.5,
                )
            ]
        )

        self.assertEqual(exit_code, 0)
        self.assertEqual(removed, [(["old-high-ratio"], True)])

    def test_rpc_listing_failure_does_not_remove_torrents(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            trackers_file = Path(tmp_dir) / "trackers.txt"
            trackers_file.write_text("preferred.example\n", encoding="utf-8")
            args = self.make_args(str(trackers_file))
            with (
                patch(
                    "main.rpc_get_torrents",
                    side_effect=TransmissionRpcError("listing failed"),
                ),
                patch("main.rpc_remove_torrents") as remove_torrents,
            ):
                with self.assertRaises(TransmissionRpcError):
                    run_once(args)

        remove_torrents.assert_not_called()

    def make_torrent(self, **overrides: object) -> dict:
        torrent = {
            "hash_string": "public",
            "name": "public",
            "added_date": NOW - 10 * DAY_SECONDS,
            "done_date": 0,
            "left_until_done": 1024,
            "percent_done": 0.5,
            "size_when_done": 0,
            "status": 4,
            "tracker_stats": [{"host": "public.example"}],
            "upload_ratio": 0.0,
        }
        torrent.update(overrides)
        return torrent

    def make_args(self, trackers_file: str, **overrides: object) -> argparse.Namespace:
        args = {
            "rpc_url": "http://127.0.0.1:9091/transmission/rpc",
            "trackers_file": trackers_file,
            "minimum_age_days": 30.0,
            "minimum_ratio": 3.0,
            "maximum_age_days": 365.0,
            "request_timeout_seconds": 20.0,
            "delete": True,
            "log_level": "INFO",
        }
        args.update(overrides)
        return argparse.Namespace(**args)

    def run_cleaner(
        self,
        torrents: list[dict],
        *,
        trackers_contents: str = "preferred.example\n",
        **arg_overrides: object,
    ) -> tuple[int, list[tuple[list[str], bool]]]:
        removed: list[tuple[list[str], bool]] = []

        def fake_remove(
            _client: object, torrent_hashes: list[str], delete_local_data: bool
        ) -> None:
            removed.append((torrent_hashes, delete_local_data))

        with tempfile.TemporaryDirectory() as tmp_dir:
            trackers_file = Path(tmp_dir) / "trackers.txt"
            trackers_file.write_text(trackers_contents, encoding="utf-8")
            args = self.make_args(str(trackers_file), **arg_overrides)
            with (
                patch("main.rpc_get_torrents", return_value=torrents),
                patch("main.rpc_remove_torrents", side_effect=fake_remove),
                patch("main.time.time", return_value=NOW),
            ):
                exit_code = run_once(args)

        return exit_code, removed


if __name__ == "__main__":
    unittest.main()
