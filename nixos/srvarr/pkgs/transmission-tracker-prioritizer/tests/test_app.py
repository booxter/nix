from dataclasses import dataclass, field
from pathlib import Path

import pytest
from prometheus_client import generate_latest
from prometheus_client.parser import text_string_to_metric_families

from transmission_tracker_prioritizer import collector, core, prioritizer


def torrent(**overrides: object) -> core.Torrent:
    values: dict[str, object] = {
        "hash_string": "public",
        "bandwidth_priority": core.TR_PRI_NORMAL,
        "upload_ratio": 0.0,
        "peers_connected": 0,
        "peers_getting_from_us": 0,
        "peers_sending_to_us": 0,
        "left_until_done": 0,
        "status": 6,
        "rate_download": 0,
        "rate_upload": 0,
        "tracker_stats": [{"host": "public.example"}],
    }
    values.update(overrides)
    return core.Torrent.model_validate(values)


@dataclass
class FakeClient:
    torrents: list[core.Torrent]
    failure: Exception | None = None
    events: list[tuple[str, list[str], int | None]] = field(default_factory=list)

    def list_torrents(self) -> list[core.Torrent]:
        if self.failure is not None:
            raise self.failure
        return self.torrents

    def set_priority(self, torrent_hashes: list[str], priority: int) -> None:
        if torrent_hashes:
            self.events.append(("priority", torrent_hashes, priority))

    def stop(self, torrent_hashes: list[str]) -> None:
        if torrent_hashes:
            self.events.append(("stop", torrent_hashes, None))


@dataclass
class FakeClock:
    current_time: float = 2_000_000_000.0
    current_monotonic: float = 100.0
    sleeps: list[float] = field(default_factory=list)

    def monotonic(self) -> float:
        return self.current_monotonic

    def time(self) -> float:
        return self.current_time

    def sleep(self, seconds: float) -> None:
        self.sleeps.append(seconds)


def policy() -> core.Policy:
    return core.Policy(
        non_preferred_low_priority_ratio_threshold=3.0,
        non_preferred_pause_ratio_threshold=6.0,
    )


def tracker_file(tmp_path: Path) -> Path:
    path = tmp_path / "trackers.txt"
    path.write_text("preferred.example\n", encoding="utf-8")
    return path


def collect(tmp_path: Path, torrents: list[core.Torrent]) -> core.IterationState:
    status, state = core.collect_iteration_state(
        FakeClient(torrents), tracker_file(tmp_path), None, policy()
    )
    assert status == "loaded:1"
    assert state is not None
    return state


@pytest.mark.parametrize(
    ("is_preferred", "bootstrap", "ratio", "expected"),
    [
        (True, True, 99.0, core.TR_PRI_HIGH),
        (False, True, 2.9, core.TR_PRI_NORMAL),
        (False, True, 3.0, core.TR_PRI_LOW),
        (False, False, 2.9, core.TR_PRI_HIGH),
        (False, False, 3.0, core.TR_PRI_LOW),
    ],
)
def test_desired_priority_policy(
    is_preferred: bool, bootstrap: bool, ratio: float, expected: int
) -> None:
    assert (
        core.torrent_desired_priority(torrent(upload_ratio=ratio), is_preferred, bootstrap, 3.0)
        == expected
    )


def test_public_torrent_is_promoted_without_preferred_upload_peers(tmp_path: Path) -> None:
    state = collect(
        tmp_path,
        [
            torrent(
                hash_string="preferred",
                bandwidth_priority=core.TR_PRI_HIGH,
                tracker_stats=[{"host": "preferred.example"}],
            ),
            torrent(hash_string="public", upload_ratio=2.9),
        ],
    )

    assert not state.preferred_bootstrap_active
    assert not state.preferred_upload_active
    assert state.high_priority_hashes == ["public"]


def test_public_torrent_is_lowered_while_preferred_peer_downloads(tmp_path: Path) -> None:
    state = collect(
        tmp_path,
        [
            torrent(
                hash_string="preferred",
                bandwidth_priority=core.TR_PRI_HIGH,
                peers_getting_from_us=1,
                rate_upload=123,
                tracker_stats=[{"announce": "https://preferred.example/announce"}],
            ),
            torrent(
                hash_string="public",
                bandwidth_priority=core.TR_PRI_HIGH,
                upload_ratio=2.9,
            ),
        ],
    )

    assert state.preferred_bootstrap_active
    assert state.preferred_upload_active
    assert state.preferred_upload_bytes_per_second == 123
    assert state.normal_priority_hashes == ["public"]


def test_pause_policy_only_stops_running_complete_public_torrents(tmp_path: Path) -> None:
    state = collect(
        tmp_path,
        [
            torrent(hash_string="running", upload_ratio=6.0),
            torrent(hash_string="stopped", upload_ratio=6.0, status=core.TR_STATUS_STOPPED),
            torrent(hash_string="incomplete", upload_ratio=6.0, left_until_done=1),
            torrent(
                hash_string="preferred",
                upload_ratio=6.0,
                tracker_stats=[{"host": "preferred.example"}],
            ),
        ],
    )

    assert state.stop_hashes == ["running"]
    assert state.low_priority_hashes == ["incomplete", "running", "stopped"]


def test_collection_counts_activity_peers_and_rates(tmp_path: Path) -> None:
    state = collect(
        tmp_path,
        [
            torrent(
                hash_string="download",
                bandwidth_priority=core.TR_PRI_LOW,
                left_until_done=100,
                peers_connected=3,
                peers_sending_to_us=1,
                rate_download=40,
            ),
            torrent(
                hash_string="seed",
                bandwidth_priority=core.TR_PRI_HIGH,
                peers_getting_from_us=1,
                rate_upload=20,
            ),
            torrent(hash_string="", peers_connected=99),
        ],
    )

    assert state.torrent_counts == {"low": 1, "normal": 0, "high": 1}
    assert state.torrent_activity_counts["downloading"]["active"] == 1
    assert state.torrent_activity_counts["seeding"]["active"] == 1
    assert state.peer_counts["low"]["connected"] == 3
    assert state.download_bytes_per_second["low"] == 40
    assert state.upload_bytes_per_second["high"] == 20


def test_missing_tracker_file_skips_rpc(tmp_path: Path) -> None:
    client = FakeClient([], failure=AssertionError("RPC must not be called"))

    status, state = core.collect_iteration_state(client, tmp_path / "missing", None, policy())

    assert status == f"missing:{tmp_path / 'missing'}"
    assert state is None


def test_updates_are_applied_before_stop(tmp_path: Path) -> None:
    client = FakeClient([])
    state = collect(
        tmp_path,
        [torrent(hash_string="public", upload_ratio=6.0)],
    )

    core.apply_priority_updates(client, state)

    assert client.events == [
        ("priority", ["public"], core.TR_PRI_LOW),
        ("stop", ["public"], None),
    ]


@dataclass
class RecordingRpc:
    response: dict[str, object]
    calls: list[tuple[str, dict[str, object] | None]] = field(default_factory=list)

    def call(self, method: str, params: dict[str, object] | None = None) -> dict[str, object]:
        self.calls.append((method, params))
        return self.response


def test_rpc_adapter_validates_and_mutates_by_hash() -> None:
    rpc = RecordingRpc({"torrents": [{"hash_string": "hash"}]})
    client = core.TransmissionClient(rpc)

    assert client.list_torrents() == [core.Torrent(hash_string="hash")]
    client.set_priority(["hash"], core.TR_PRI_HIGH)
    client.stop(["hash"])

    assert [call[0] for call in rpc.calls] == ["torrent_get", "torrent_set", "torrent_stop"]
    assert rpc.calls[1][1] == {"ids": ["hash"], "bandwidth_priority": core.TR_PRI_HIGH}

    with pytest.raises(core.TransmissionRpcError, match="invalid torrent list"):
        core.TransmissionClient(RecordingRpc({"torrents": "bad"})).list_torrents()


def metric_samples(registry: object) -> dict[tuple[str, tuple[tuple[str, str], ...]], float]:
    text = generate_latest(registry).decode("utf-8")
    return {
        (sample.name, tuple(sorted(sample.labels.items()))): sample.value
        for family in text_string_to_metric_families(text)
        for sample in family.samples
    }


def test_success_metrics_use_native_prometheus_registry(tmp_path: Path) -> None:
    state = collect(
        tmp_path,
        [
            torrent(
                hash_string="preferred",
                bandwidth_priority=core.TR_PRI_HIGH,
                peers_getting_from_us=1,
                rate_upload=20,
                tracker_stats=[{"host": "preferred.example"}],
            )
        ],
    )

    samples = metric_samples(core.success_registry(state, 123.0))

    assert samples[("host_observability_transmission_torrent_count", (("class", "high"),))] == 1
    assert samples[("host_observability_transmission_preferred_upload_active", ())] == 1
    assert samples[("host_observability_transmission_exporter_ok", ())] == 1
    assert (
        samples[("host_observability_transmission_exporter_last_success_timestamp_seconds", ())]
        == 123.0
    )


def test_health_textfile_is_atomic_and_world_readable(tmp_path: Path) -> None:
    destination = tmp_path / "transmission.prom"

    core.write_health_metrics(
        destination,
        exporter_ok=False,
        last_run_timestamp_seconds=200.0,
        last_success_timestamp_seconds=100.0,
    )

    assert destination.stat().st_mode & 0o777 == 0o644
    assert "host_observability_transmission_exporter_ok 0.0" in destination.read_text()


def daemon_settings(tmp_path: Path) -> core.DaemonSettings:
    return core.DaemonSettings(
        rpc_url="http://127.0.0.1:9091/transmission/rpc",
        trackers_file=tracker_file(tmp_path),
        interval_seconds=30.0,
        request_timeout_seconds=20.0,
        policy=policy(),
    )


def test_prioritizer_daemon_runs_bounded_iterations(tmp_path: Path) -> None:
    client = FakeClient([torrent(upload_ratio=6.0)])
    clock = FakeClock()

    prioritizer.run(daemon_settings(tmp_path), client, clock, iterations=2)

    assert len(client.events) == 4
    assert clock.sleeps == [30.0]


def test_collector_writes_failure_health_after_rpc_error(tmp_path: Path) -> None:
    metrics_file = tmp_path / "collector.prom"
    client = FakeClient([], failure=core.TransmissionRpcError("unavailable"))

    collector.run(
        collector.CollectorSettings(daemon_settings(tmp_path), metrics_file),
        client,
        FakeClock(),
        iterations=1,
    )

    text = metrics_file.read_text(encoding="utf-8")
    assert "host_observability_transmission_exporter_ok 0.0" in text


def test_cli_entry_points_build_typed_settings(tmp_path: Path) -> None:
    trackers = tracker_file(tmp_path)
    metrics = tmp_path / "metrics.prom"
    seen: list[object] = []

    def run_prioritizer(
        settings: core.DaemonSettings,
        client: core.TorrentClient,
        clock: core.Clock,
        *,
        iterations: int | None = None,
    ) -> None:
        seen.append(settings)

    def run_collector(
        settings: collector.CollectorSettings,
        client: core.TorrentClient,
        clock: core.Clock,
        *,
        iterations: int | None = None,
    ) -> None:
        seen.append(settings)

    assert prioritizer.main(["--trackers-file", str(trackers)], run_prioritizer) == 0
    assert (
        collector.main(
            ["--trackers-file", str(trackers), "--metrics-file", str(metrics)],
            run_collector,
        )
        == 0
    )
    assert isinstance(seen[0], core.DaemonSettings)
    assert seen[1] == collector.CollectorSettings(seen[0], metrics)
