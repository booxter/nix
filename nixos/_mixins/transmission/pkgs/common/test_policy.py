import tempfile
import unittest
from pathlib import Path

from transmission_common.policy import (
    CleanupPolicy,
    CompletedCleanupPolicy,
    PolicyConfigError,
    Priority,
    RatioPriorityPolicy,
    StopPolicy,
    TorrentClassPolicy,
    cleanup_reasons,
    desired_priority,
    load_policy,
    should_stop,
)


def ratio_policy(after: Priority = Priority.LOW) -> RatioPriorityPolicy:
    return RatioPriorityPolicy(
        target_ratio=3.0,
        below_target=Priority.HIGH,
        at_or_above_target=after,
    )


class PolicyTests(unittest.TestCase):
    def test_priority_uses_inclusive_ratio_boundary(self) -> None:
        policy = ratio_policy(Priority.NORMAL)

        self.assertEqual(desired_priority(policy, None), Priority.HIGH)
        self.assertEqual(desired_priority(policy, 2.9), Priority.HIGH)
        self.assertEqual(desired_priority(policy, 3.0), Priority.NORMAL)

    def test_stop_requires_configured_ratio_and_completion(self) -> None:
        policy = StopPolicy(minimum_ratio=6.0, require_complete=True)

        self.assertFalse(should_stop(None, ratio=99.0, complete=True))
        self.assertFalse(should_stop(policy, ratio=5.9, complete=True))
        self.assertFalse(should_stop(policy, ratio=6.0, complete=False))
        self.assertTrue(should_stop(policy, ratio=6.0, complete=True))

    def test_cleanup_uses_completion_and_total_age_boundaries(self) -> None:
        policy = CleanupPolicy(
            completed=CompletedCleanupPolicy(minimum_ratio=3.0, minimum_age_days=30.0),
            maximum_age_days=365.0,
        )

        self.assertEqual(
            cleanup_reasons(
                policy,
                ratio=3.0,
                complete=True,
                completion_age_days=30.0,
                added_age_days=100.0,
            ),
            ("high-ratio",),
        )
        self.assertEqual(
            cleanup_reasons(
                policy,
                ratio=0.0,
                complete=False,
                completion_age_days=None,
                added_age_days=365.0,
            ),
            ("maximum-age",),
        )
        self.assertEqual(
            cleanup_reasons(
                None,
                ratio=99.0,
                complete=True,
                completion_age_days=999.0,
                added_age_days=999.0,
            ),
            (),
        )

    def test_class_policy_rejects_reversed_thresholds(self) -> None:
        with self.assertRaisesRegex(ValueError, "stop minimum_ratio"):
            TorrentClassPolicy(
                priority=ratio_policy(),
                stop=StopPolicy(minimum_ratio=2.0, require_complete=True),
                cleanup=None,
            )

    def test_load_policy_rejects_unknown_fields(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            path = Path(tmp_dir) / "policy.json"
            path.write_text('{"preferred": {}, "non_preferred": {}, "extra": true}')

            with self.assertRaisesRegex(PolicyConfigError, "invalid torrent policy"):
                load_policy(path)


if __name__ == "__main__":
    unittest.main()
