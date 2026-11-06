import json
from collections.abc import Sequence
from dataclasses import dataclass, field
from pathlib import Path

import pytest
from transmission_common.policy import (
    ActivityPolicy,
    CleanupPolicy,
    CompletedCleanupPolicy,
    Priority,
    RatioPriorityPolicy,
    RetentionPolicy,
    StopPolicy,
    TorrentClassPolicy,
    TorrentPolicy,
)
from transmission_torrent_cleaner import app
from transmission_torrent_cleaner.history import Sample, TorrentHistory, UploadHistory

NOW = 2_000_000_000.0
DAY = 86_400
ALIASES = {"tracker1": "preferred.example", "tracker2": "second.example"}


def torrent(name: str = "public", **overrides: object) -> app.Torrent:
    values: dict[str, object] = {
        "hash_string": name,
        "name": name,
        "added_date": int(NOW) - 400 * DAY,
        "done_date": int(NOW) - 90 * DAY,
        "left_until_done": 0,
        "tracker_stats": [{"host": "public.example"}],
        "upload_ratio": 3.0,
        "uploaded_ever": 1000,
        "seconds_seeding": 3 * DAY,
    }
    values.update(overrides)
    return app.Torrent.model_validate(values)


def special(name: str, **overrides: object) -> app.Torrent:
    return torrent(name, **({"tracker_stats": [{"host": "preferred.example"}]} | overrides))


def policy(floor: int = 1) -> TorrentPolicy:
    def priority(after: Priority) -> RatioPriorityPolicy:
        return RatioPriorityPolicy(
            target_ratio=3.0, below_target=Priority.HIGH, at_or_above_target=after
        )

    return TorrentPolicy(
        preferred=TorrentClassPolicy(priority=priority(Priority.NORMAL), stop=None, cleanup=None),
        non_preferred=TorrentClassPolicy(
            priority=priority(Priority.LOW),
            stop=StopPolicy(minimum_ratio=6.0, require_complete=True),
            cleanup=CleanupPolicy(
                completed=CompletedCleanupPolicy(minimum_ratio=3.0, minimum_age_days=30.0),
                maximum_age_days=365.0,
            ),
        ),
        trackers={
            alias: RetentionPolicy(minimum_retained=floor, minimum_seed_days=3.0)
            for alias in ALIASES
        },
        activity=ActivityPolicy(window_days=14.0, minimum_upload_bytes_per_second=10240.0),
    )


def candidates(torrents: list[app.Torrent], rates: dict[str, float] | None = None) -> list[str]:
    selected = app.select_candidates(torrents, ALIASES, policy(), NOW, rates or {})
    return [candidate.hash for candidate in selected]


@pytest.mark.parametrize(
    "overrides",
    [
        {"done_date": int(NOW) - 29 * DAY},
        {"done_date": 0},
        {"done_date": int(NOW) + DAY},
        {"left_until_done": 100},
        {"left_until_done": None},
        {"hash_string": ""},
        {"name": ""},
    ],
)
def test_generic_cleanup_never_bypasses_completion_protection(overrides: dict[str, object]) -> None:
    assert candidates([torrent(**overrides)]) == []


@pytest.mark.parametrize(
    ("added_days", "ratio", "expected"),
    [
        (364, 2.9, []),
        (365, 0.1, ["public"]),
        (40, 3.0, ["public"]),
    ],
)
def test_generic_ratio_and_maximum_age_rules(
    added_days: int, ratio: float, expected: list[str]
) -> None:
    item = torrent(
        added_date=int(NOW) - added_days * DAY, done_date=int(NOW) - 30 * DAY, upload_ratio=ratio
    )
    assert candidates([item]) == expected


def test_oldest_low_upload_special_torrents_removed_down_to_floor() -> None:
    items = [
        special("newer"),
        special("oldest", done_date=int(NOW) - 100 * DAY),
        special("productive"),
    ]
    assert candidates(items, {"oldest": 0.0, "newer": 10239.0, "productive": 10240.0}) == [
        "oldest",
        "newer",
    ]


def test_no_batch_limit_and_incomplete_torrents_do_not_count_towards_floor() -> None:
    items = [special(str(index)) for index in range(20)] + [
        special("downloading", left_until_done=1)
    ]
    selected = candidates(items, {item.hash_string: 0.0 for item in items})
    assert len(selected) == 19
    assert "downloading" not in selected


@pytest.mark.parametrize(
    "overrides",
    [
        {"seconds_seeding": 3 * DAY - 1},
        {"seconds_seeding": None},
        {"done_date": int(NOW) - 29 * DAY},
    ],
)
def test_special_tracker_requirements_protect_surplus(overrides: dict[str, object]) -> None:
    assert (
        candidates([special("protected", **overrides), special("other")], {"protected": 0.0}) == []
    )


def test_unknown_activity_protects_special_torrent() -> None:
    assert candidates([special("unobserved"), special("other")]) == []


def test_all_matching_tracker_floors_are_preserved() -> None:
    shared = special(
        "shared",
        tracker_stats=[
            {"host": "preferred.example"},
            {"announce": "https://second.example/announce"},
        ],
    )
    assert candidates([shared, special("other")], {"shared": 0.0, "other": 0.0}) == ["other"]


def test_all_matching_tracker_seeding_requirements_are_preserved() -> None:
    shared = special(
        "shared", tracker_stats=[{"host": "preferred.example"}, {"host": "second.example"}]
    )
    configured = policy(0)
    configured.trackers["tracker2"] = RetentionPolicy(minimum_retained=0, minimum_seed_days=4.0)
    assert app.select_candidates([shared], ALIASES, configured, NOW, {"shared": 0.0}) == []


@dataclass
class FakeClient:
    torrents: list[app.Torrent]
    refreshed: list[app.Torrent] | None = None
    failure: app.TransmissionRpcError | None = None
    removed: list[str] = field(default_factory=list)
    listed: bool = False

    def list_torrents(self) -> list[app.Torrent]:
        if self.failure is not None:
            raise self.failure
        if self.listed and self.refreshed is not None:
            return self.refreshed
        self.listed = True
        return self.torrents

    def remove_torrents(self, torrent_hashes: Sequence[str], *, delete_local_data: bool) -> None:
        assert delete_local_data
        self.removed.extend(torrent_hashes)


@dataclass
class MemoryHistory:
    history: UploadHistory = field(default_factory=UploadHistory)
    fail_save: bool = False

    def load(self) -> UploadHistory:
        return self.history

    def save(self, history: UploadHistory) -> None:
        if self.fail_save:
            raise OSError("history storage unavailable")
        self.history = history


@dataclass(frozen=True)
class FrozenClock:
    def now(self) -> float:
        return NOW


def settings(tmp_path: Path, *, delete: bool = True) -> app.Settings:
    trackers_file = tmp_path / "trackers.json"
    trackers_file.write_text(json.dumps(ALIASES))
    return app.Settings(
        rpc_url="http://127.0.0.1:9091/transmission/rpc",
        trackers_file=trackers_file,
        request_timeout_seconds=20.0,
        policy=policy(),
        delete=delete,
    )


def mature_history(items: list[app.Torrent]) -> MemoryHistory:
    return MemoryHistory(
        UploadHistory(
            torrents={
                item.hash_string: TorrentHistory(
                    completed_at=item.done_date,
                    last_observation=Sample(timestamp=NOW - 3600, uploaded_bytes=1000),
                    samples=[
                        Sample(timestamp=NOW - hour * 3600, uploaded_bytes=1000)
                        for hour in range(14 * 24, 0, -1)
                    ],
                )
                for item in items
            }
        )
    )


def test_dry_run_observes_without_removing(tmp_path: Path) -> None:
    client = FakeClient([torrent()])
    store = MemoryHistory()
    assert app.run_cleanup(settings(tmp_path, delete=False), client, FrozenClock(), store) == 0
    assert client.removed == []
    assert "public" in store.history.torrents


def test_cleanup_applies_special_floor_with_mature_history(tmp_path: Path) -> None:
    items = [special("oldest", done_date=int(NOW) - 100 * DAY), special("newer")]
    client = FakeClient(items)
    assert app.run_cleanup(settings(tmp_path), client, FrozenClock(), mature_history(items)) == 0
    assert client.removed == ["oldest"]


def test_cleanup_rechecks_recent_downloads_before_deletion(tmp_path: Path) -> None:
    client = FakeClient([torrent()], refreshed=[torrent(done_date=int(NOW))])
    assert app.run_cleanup(settings(tmp_path), client, FrozenClock(), MemoryHistory()) == 0
    assert client.removed == []


def test_cleanup_rechecks_tracker_floors_before_deletion(tmp_path: Path) -> None:
    items = [special("oldest", done_date=int(NOW) - 100 * DAY), special("newer")]
    client = FakeClient(items, refreshed=[items[0]])
    assert app.run_cleanup(settings(tmp_path), client, FrozenClock(), mature_history(items)) == 0
    assert client.removed == []


def test_cleanup_rechecks_upload_before_deletion(tmp_path: Path) -> None:
    items = [special("oldest", done_date=int(NOW) - 100 * DAY), special("newer")]
    productive = items[0].model_copy(update={"uploaded_ever": 14 * DAY * 10240 + 1000})
    client = FakeClient(items, refreshed=[productive, items[1]])
    assert app.run_cleanup(settings(tmp_path), client, FrozenClock(), mature_history(items)) == 0
    assert client.removed == []


def test_counter_reset_during_recheck_restarts_persistent_history(tmp_path: Path) -> None:
    items = [special("oldest", done_date=int(NOW) - 100 * DAY), special("newer")]
    reset = items[0].model_copy(update={"uploaded_ever": 0})
    client = FakeClient(items, refreshed=[reset, items[1]])
    store = mature_history(items)
    assert app.run_cleanup(settings(tmp_path), client, FrozenClock(), store) == 0
    assert client.removed == []
    assert store.history.torrents["oldest"].last_observation.uploaded_bytes == 0
    assert len(store.history.torrents["oldest"].samples) == 1


def test_missing_alias_mapping_stops_cleanup(tmp_path: Path) -> None:
    config = settings(tmp_path)
    config.trackers_file.write_text("{}")
    client = FakeClient([torrent()])
    with pytest.raises(app.PolicyConfigError):
        app.run_cleanup(config, client, FrozenClock(), MemoryHistory())
    assert client.removed == []


def test_storage_failure_stops_cleanup(tmp_path: Path) -> None:
    client = FakeClient([torrent()])
    with pytest.raises(OSError, match="storage unavailable"):
        app.run_cleanup(settings(tmp_path), client, FrozenClock(), MemoryHistory(fail_save=True))
    assert client.removed == []


def test_rpc_failure_stops_cleanup(tmp_path: Path) -> None:
    client = FakeClient([], failure=app.TransmissionRpcError("listing failed"))
    with pytest.raises(app.TransmissionRpcError, match="listing failed"):
        app.run_cleanup(settings(tmp_path), client, FrozenClock(), MemoryHistory())
    assert client.removed == []


def test_missing_counters_and_incomplete_torrents_drop_history() -> None:
    items = [special("missing", uploaded_ever=None), special("incomplete", left_until_done=1)]
    history, rates = app.collect_upload_history(items, mature_history(items).history, policy(), NOW)
    assert history.torrents == {}
    assert rates == {}


@dataclass
class FakeRpc:
    response: dict[str, object]

    def call(self, method: str, params: dict[str, object] | None = None) -> dict[str, object]:
        return self.response


def test_rpc_adapter_rejects_invalid_listing() -> None:
    with pytest.raises(app.TransmissionRpcError, match="invalid torrent list"):
        app.TransmissionClient(FakeRpc({"torrents": "invalid"})).list_torrents()


def test_missing_tracker_information_rejects_listing() -> None:
    with pytest.raises(app.TransmissionRpcError, match="invalid torrent list"):
        app.TransmissionClient(FakeRpc({"torrents": [{"hash_string": "unknown"}]})).list_torrents()


def test_unidentified_tracker_rejects_listing() -> None:
    item = torrent().model_dump() | {"tracker_stats": [{}]}
    with pytest.raises(app.TransmissionRpcError, match="invalid torrent list"):
        app.TransmissionClient(FakeRpc({"torrents": [item]})).list_torrents()


def test_trackerless_torrent_uses_generic_policy() -> None:
    assert candidates([torrent(tracker_stats=[])]) == ["public"]


def test_rpc_adapter_reads_counters() -> None:
    item = special("seed")
    client = app.TransmissionClient(FakeRpc({"torrents": [item.model_dump()]}))
    assert client.list_torrents() == [item]


def test_main_reports_missing_tracker_file(tmp_path: Path) -> None:
    policy_path = tmp_path / "policy.json"
    policy_path.write_text(policy().model_dump_json())
    assert (
        app.main(
            [
                "--trackers-file",
                str(tmp_path / "missing"),
                "--policy-file",
                str(policy_path),
                "--history-file",
                str(tmp_path / "history.json"),
            ]
        )
        == 1
    )
