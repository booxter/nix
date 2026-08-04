from dataclasses import dataclass, field
from pathlib import Path

import pytest

from transmission_torrent_cleaner import app


NOW = 2_000_000_000.0
DAY_SECONDS = 86_400


def torrent(**overrides: object) -> app.Torrent:
    values: dict[str, object] = {
        "hash_string": "public",
        "name": "public",
        "added_date": int(NOW) - 10 * DAY_SECONDS,
        "done_date": 0,
        "left_until_done": 1024,
        "percent_done": 0.5,
        "size_when_done": 0,
        "tracker_stats": [{"host": "public.example"}],
        "upload_ratio": 0.0,
    }
    values.update(overrides)
    return app.Torrent.model_validate(values)


@dataclass
class FakeClient:
    torrents: list[app.Torrent]
    failure: app.TransmissionRpcError | None = None
    removed: list[tuple[list[str], bool]] = field(default_factory=list)

    def list_torrents(self) -> list[app.Torrent]:
        if self.failure is not None:
            raise self.failure
        return self.torrents

    def remove_torrents(self, torrent_hashes: list[str], *, delete_local_data: bool) -> None:
        self.removed.append((torrent_hashes, delete_local_data))


@dataclass(frozen=True)
class FrozenClock:
    def now(self) -> float:
        return NOW


def settings(trackers_file: Path, *, delete: bool = True) -> app.Settings:
    return app.Settings(
        rpc_url="http://127.0.0.1:9091/transmission/rpc",
        trackers_file=trackers_file,
        request_timeout_seconds=20.0,
        policy=app.Policy(
            minimum_age_days=30.0,
            minimum_ratio=3.0,
            maximum_age_days=365.0,
        ),
        delete=delete,
    )


def run_cleaner(
    tmp_path: Path, torrents: list[app.Torrent], *, delete: bool = True
) -> tuple[int, FakeClient]:
    trackers_file = tmp_path / "trackers.txt"
    trackers_file.write_text("preferred.example\n", encoding="utf-8")
    client = FakeClient(torrents)
    result = app.run_cleanup(settings(trackers_file, delete=delete), client, FrozenClock())
    return result, client


def test_over_age_incomplete_torrent_is_deleted(tmp_path: Path) -> None:
    result, client = run_cleaner(
        tmp_path,
        [
            torrent(
                hash_string="old-public",
                name="old-public",
                added_date=int(NOW) - 366 * DAY_SECONDS,
                left_until_done=1024,
                percent_done=0.5,
                done_date=0,
                upload_ratio=0.2,
            )
        ],
    )

    assert result == 0
    assert client.removed == [(["old-public"], True)]


def test_over_age_low_ratio_seeding_torrent_is_deleted(tmp_path: Path) -> None:
    result, client = run_cleaner(
        tmp_path,
        [
            torrent(
                hash_string="still-seeding",
                name="still-seeding",
                added_date=int(NOW) - 366 * DAY_SECONDS,
                done_date=int(NOW) - 366 * DAY_SECONDS,
                left_until_done=0,
                percent_done=1.0,
                upload_ratio=0.2,
            )
        ],
    )

    assert result == 0
    assert client.removed == [(["still-seeding"], True)]


def test_under_age_low_ratio_seeding_torrent_is_kept(tmp_path: Path) -> None:
    result, client = run_cleaner(
        tmp_path,
        [
            torrent(
                hash_string="young-seeding",
                name="young-seeding",
                added_date=int(NOW) - 364 * DAY_SECONDS,
                done_date=int(NOW) - 364 * DAY_SECONDS,
                left_until_done=0,
                percent_done=1.0,
                upload_ratio=2.9,
            )
        ],
    )

    assert result == 0
    assert client.removed == []


def test_preferred_torrent_is_exempt_by_host_or_announce(tmp_path: Path) -> None:
    result, client = run_cleaner(
        tmp_path,
        [
            torrent(
                hash_string="preferred-host",
                name="preferred-host",
                added_date=int(NOW) - 366 * DAY_SECONDS,
                tracker_stats=[{"host": "preferred.example"}],
            ),
            torrent(
                hash_string="preferred-announce",
                name="preferred-announce",
                added_date=int(NOW) - 366 * DAY_SECONDS,
                tracker_stats=[{"announce": "https://preferred.example/announce"}],
            ),
        ],
    )

    assert result == 0
    assert client.removed == []


def test_old_complete_high_ratio_torrent_is_deleted(tmp_path: Path) -> None:
    result, client = run_cleaner(
        tmp_path,
        [
            torrent(
                hash_string="old-high-ratio",
                name="old-high-ratio",
                added_date=int(NOW) - 90 * DAY_SECONDS,
                done_date=int(NOW) - 45 * DAY_SECONDS,
                left_until_done=0,
                percent_done=1.0,
                upload_ratio=3.5,
            )
        ],
    )

    assert result == 0
    assert client.removed == [(["old-high-ratio"], True)]


def test_dry_run_orders_candidates_without_removing(tmp_path: Path) -> None:
    trackers_file = tmp_path / "trackers.txt"
    trackers_file.write_text("preferred.example\n", encoding="utf-8")
    candidates = app.select_candidates(
        [
            torrent(name="lower-ratio", hash_string="lower", upload_ratio=3.1, done_date=1),
            torrent(name="higher-ratio", hash_string="higher", upload_ratio=4.0, done_date=1),
            torrent(hash_string="missing", name=""),
        ],
        {"preferred.example"},
        settings(trackers_file).policy,
        NOW,
    )
    client = FakeClient([torrent(added_date=int(NOW) - 366 * DAY_SECONDS)])

    result = app.run_cleanup(settings(trackers_file, delete=False), client, FrozenClock())

    assert [candidate.hash for candidate in candidates] == ["higher", "lower"]
    assert result == 0
    assert client.removed == []


def test_rpc_listing_failure_does_not_remove_torrents(tmp_path: Path) -> None:
    trackers_file = tmp_path / "trackers.txt"
    trackers_file.write_text("preferred.example\n", encoding="utf-8")
    client = FakeClient([], failure=app.TransmissionRpcError("listing failed"))

    with pytest.raises(app.TransmissionRpcError, match="listing failed"):
        app.run_cleanup(settings(trackers_file), client, FrozenClock())

    assert client.removed == []


@dataclass
class RecordingRpc:
    response: dict[str, object]
    calls: list[tuple[str, dict[str, object] | None]] = field(default_factory=list)

    def call(self, method: str, params: dict[str, object] | None = None) -> dict[str, object]:
        self.calls.append((method, params))
        return self.response


def test_rpc_adapter_validates_listing_and_removes_by_hash() -> None:
    rpc = RecordingRpc({"torrents": [{"hash_string": "hash", "name": "name"}]})
    client = app.TransmissionClient(rpc)

    assert client.list_torrents() == [app.Torrent(hash_string="hash", name="name")]
    client.remove_torrents(["hash"], delete_local_data=True)

    assert rpc.calls[0][0] == "torrent_get"
    assert rpc.calls[1] == (
        "torrent_remove",
        {"ids": ["hash"], "delete_local_data": True},
    )

    with pytest.raises(app.TransmissionRpcError, match="invalid torrent list"):
        app.TransmissionClient(RecordingRpc({"torrents": "invalid"})).list_torrents()


def test_timestamp_fallbacks_preserve_cleanup_policy() -> None:
    added_only = torrent(added_date=100, done_date=0)
    completed_only = torrent(added_date=0, done_date=200)
    undated = torrent(added_date=0, done_date=0)

    assert app.torrent_completion_timestamp(added_only) == 100
    assert app.torrent_added_timestamp(completed_only) == 200
    assert app.torrent_completion_timestamp(undated) is None
    assert app.torrent_added_timestamp(undated) is None


def test_main_reports_missing_tracker_file(tmp_path: Path) -> None:
    result = app.main(["--trackers-file", str(tmp_path / "missing")])

    assert result == 1
