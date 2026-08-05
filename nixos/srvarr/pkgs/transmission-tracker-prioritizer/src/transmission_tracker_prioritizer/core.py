import argparse
import logging
import os
import time
from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Literal, Protocol

from prometheus_client import CollectorRegistry, Gauge, write_to_textfile
from pydantic import BaseModel, ConfigDict, Field, ValidationError
from transmission_common.transmission import (
    TransmissionRpcClient,
    TransmissionRpcError,
    normalize_tracker_host,
    read_tracker_hosts,
)


LOG = logging.getLogger("transmission-tracker-common")
TR_PRI_LOW = -1
TR_PRI_NORMAL = 0
TR_PRI_HIGH = 1
TR_STATUS_STOPPED = 0
PriorityClass = Literal["low", "normal", "high"]
PRIORITY_CLASSES: tuple[PriorityClass, ...] = ("low", "normal", "high")
DEFAULT_NON_PREFERRED_LOW_PRIORITY_RATIO_THRESHOLD = 3.0
DEFAULT_NON_PREFERRED_PAUSE_RATIO_THRESHOLD = 6.0
TORRENT_FIELDS = [
    "id",
    "name",
    "hash_string",
    "bandwidth_priority",
    "peers_connected",
    "peers_getting_from_us",
    "peers_sending_to_us",
    "left_until_done",
    "status",
    "upload_ratio",
    "rate_download",
    "rate_upload",
    "tracker_stats",
]


class Tracker(BaseModel):
    model_config = ConfigDict(extra="allow", frozen=True, strict=True)

    host: str | None = None
    announce: str | None = None


class Torrent(BaseModel):
    model_config = ConfigDict(extra="allow", frozen=True, strict=True)

    hash_string: str = ""
    bandwidth_priority: int = TR_PRI_NORMAL
    peers_connected: int = 0
    peers_getting_from_us: int = 0
    peers_sending_to_us: int = 0
    left_until_done: int | None = None
    status: int | None = None
    upload_ratio: int | float | None = None
    rate_download: int = 0
    rate_upload: int = 0
    tracker_stats: list[Tracker] = Field(default_factory=list)


class TorrentList(BaseModel):
    model_config = ConfigDict(extra="allow", frozen=True, strict=True)

    torrents: list[Torrent] = Field(default_factory=list)


class RpcTransport(Protocol):
    def call(self, method: str, params: dict[str, object] | None = None) -> dict[str, object]: ...


class TorrentClient(Protocol):
    def list_torrents(self) -> list[Torrent]: ...

    def set_priority(self, torrent_hashes: Sequence[str], priority: int) -> None: ...

    def stop(self, torrent_hashes: Sequence[str]) -> None: ...


class Clock(Protocol):
    def monotonic(self) -> float: ...

    def time(self) -> float: ...

    def sleep(self, seconds: float) -> None: ...


@dataclass(frozen=True)
class SystemClock:
    def monotonic(self) -> float:
        return time.monotonic()

    def time(self) -> float:
        return time.time()

    def sleep(self, seconds: float) -> None:
        time.sleep(seconds)


@dataclass(frozen=True)
class TransmissionClient:
    rpc: RpcTransport

    def list_torrents(self) -> list[Torrent]:
        response: object = self.rpc.call("torrent_get", {"fields": TORRENT_FIELDS})
        try:
            return TorrentList.model_validate(response).torrents
        except ValidationError as exc:
            raise TransmissionRpcError(
                f"Transmission RPC returned an invalid torrent list: {exc}"
            ) from exc

    def set_priority(self, torrent_hashes: Sequence[str], priority: int) -> None:
        if torrent_hashes:
            self.rpc.call(
                "torrent_set",
                {
                    "ids": list(torrent_hashes),
                    "bandwidth_priority": priority,
                },
            )

    def stop(self, torrent_hashes: Sequence[str]) -> None:
        if torrent_hashes:
            self.rpc.call("torrent_stop", {"ids": list(torrent_hashes)})


@dataclass(frozen=True)
class Policy:
    non_preferred_low_priority_ratio_threshold: float
    non_preferred_pause_ratio_threshold: float


@dataclass(frozen=True)
class DaemonSettings:
    rpc_url: str
    trackers_file: Path
    interval_seconds: float
    request_timeout_seconds: float
    policy: Policy


PriorityCounts = dict[PriorityClass, int]
NestedCounts = dict[str, PriorityCounts]
PeerCounts = dict[PriorityClass, dict[str, int]]


@dataclass(frozen=True)
class IterationState:
    tracker_hosts_count: int
    preferred_torrent_count: int
    preferred_bootstrap_active: bool
    preferred_upload_active: bool
    preferred_upload_bytes_per_second: int
    torrent_counts: PriorityCounts
    torrent_activity_counts: dict[str, dict[str, int]]
    bandwidth_active_torrent_counts: NestedCounts
    peer_counts: PeerCounts
    download_bytes_per_second: PriorityCounts
    upload_bytes_per_second: PriorityCounts
    high_priority_hashes: list[str]
    normal_priority_hashes: list[str]
    low_priority_hashes: list[str]
    stop_hashes: list[str]


def load_tracker_hosts(trackers_file: Path) -> set[str] | None:
    if not trackers_file.exists():
        return None
    try:
        return read_tracker_hosts(
            trackers_file,
            on_empty_entry=lambda line_number: LOG.warning(
                "ignoring empty tracker host entry on line %s", line_number
            ),
        )
    except OSError as exc:
        LOG.warning("unable to read tracker host file %s: %s", trackers_file, exc)
        return None


def tracker_matches(torrent: Torrent, tracker_hosts: set[str]) -> bool:
    for tracker in torrent.tracker_stats:
        for raw_host in (tracker.host, tracker.announce):
            if raw_host is None:
                continue
            host = normalize_tracker_host(raw_host)
            if host and host in tracker_hosts:
                return True
    return False


def nonnegative(value: int) -> int:
    return max(0, value)


def priority_class_name(priority: int) -> PriorityClass:
    if priority <= TR_PRI_LOW:
        return "low"
    if priority >= TR_PRI_HIGH:
        return "high"
    return "normal"


def torrent_is_complete(torrent: Torrent) -> bool:
    return torrent.left_until_done == 0


def torrent_desired_priority(
    torrent: Torrent,
    is_preferred: bool,
    preferred_bootstrap_active: bool,
    non_preferred_low_priority_ratio_threshold: float,
) -> int:
    if is_preferred:
        return TR_PRI_HIGH
    baseline = TR_PRI_NORMAL
    if (
        torrent.upload_ratio is not None
        and torrent.upload_ratio >= non_preferred_low_priority_ratio_threshold
    ):
        baseline = TR_PRI_LOW
    if preferred_bootstrap_active:
        return baseline
    return TR_PRI_HIGH if baseline == TR_PRI_NORMAL else TR_PRI_LOW


def collect_iteration_state(
    client: TorrentClient,
    trackers_file: Path,
    last_tracker_status: str | None,
    policy: Policy,
) -> tuple[str | None, IterationState | None]:
    tracker_hosts = load_tracker_hosts(trackers_file)
    if tracker_hosts is None:
        status = f"missing:{trackers_file}"
        if status != last_tracker_status:
            LOG.warning(
                "tracker host file %s does not exist yet; skipping until it is created",
                trackers_file,
            )
        return status, None

    entries: list[tuple[Torrent, bool]] = []
    preferred_hashes: set[str] = set()
    for torrent in client.list_torrents():
        if not torrent.hash_string:
            continue
        is_preferred = tracker_matches(torrent, tracker_hosts)
        if is_preferred:
            preferred_hashes.add(torrent.hash_string)
        entries.append((torrent, is_preferred))

    preferred_bootstrap_active = any(
        is_preferred and torrent.peers_getting_from_us > 0 for torrent, is_preferred in entries
    )
    torrent_counts: PriorityCounts = {torrent_class: 0 for torrent_class in PRIORITY_CLASSES}
    activity_counts = {
        "seeding": {"active": 0, "inactive": 0},
        "downloading": {"active": 0, "inactive": 0},
    }
    bandwidth_counts: NestedCounts = {
        direction: {torrent_class: 0 for torrent_class in PRIORITY_CLASSES}
        for direction in ("download", "upload")
    }
    peer_counts: PeerCounts = {
        torrent_class: {"connected": 0, "getting_from_us": 0, "sending_to_us": 0}
        for torrent_class in PRIORITY_CLASSES
    }
    downloads: PriorityCounts = {torrent_class: 0 for torrent_class in PRIORITY_CLASSES}
    uploads: PriorityCounts = {torrent_class: 0 for torrent_class in PRIORITY_CLASSES}
    high: list[str] = []
    normal: list[str] = []
    low: list[str] = []
    stop: list[str] = []
    preferred_upload_active = False
    preferred_upload_bytes_per_second = 0

    for torrent, is_preferred in entries:
        torrent_class = priority_class_name(torrent.bandwidth_priority)
        torrent_counts[torrent_class] += 1
        peer_counts[torrent_class]["connected"] += nonnegative(torrent.peers_connected)
        peer_counts[torrent_class]["getting_from_us"] += nonnegative(torrent.peers_getting_from_us)
        peer_counts[torrent_class]["sending_to_us"] += nonnegative(torrent.peers_sending_to_us)
        downloads[torrent_class] += nonnegative(torrent.rate_download)
        uploads[torrent_class] += nonnegative(torrent.rate_upload)
        active_download = torrent.peers_sending_to_us > 0 or torrent.rate_download > 0
        active_upload = torrent.peers_getting_from_us > 0 or torrent.rate_upload > 0
        if active_download:
            bandwidth_counts["download"][torrent_class] += 1
        if active_upload:
            bandwidth_counts["upload"][torrent_class] += 1
        if torrent.left_until_done is not None:
            direction = "downloading" if torrent.left_until_done > 0 else "seeding"
            active = active_download if direction == "downloading" else active_upload
            activity_counts[direction]["active" if active else "inactive"] += 1

        if (
            not is_preferred
            and torrent_is_complete(torrent)
            and torrent.upload_ratio is not None
            and torrent.upload_ratio >= policy.non_preferred_pause_ratio_threshold
            and torrent.status != TR_STATUS_STOPPED
        ):
            stop.append(torrent.hash_string)

        desired = torrent_desired_priority(
            torrent,
            is_preferred,
            preferred_bootstrap_active,
            policy.non_preferred_low_priority_ratio_threshold,
        )
        if is_preferred:
            preferred_upload_bytes_per_second += nonnegative(torrent.rate_upload)
            preferred_upload_active |= torrent.peers_getting_from_us > 0
        if desired == TR_PRI_HIGH and torrent.bandwidth_priority != TR_PRI_HIGH:
            high.append(torrent.hash_string)
        elif desired == TR_PRI_NORMAL and torrent.bandwidth_priority != TR_PRI_NORMAL:
            normal.append(torrent.hash_string)
        elif desired == TR_PRI_LOW and torrent.bandwidth_priority != TR_PRI_LOW:
            low.append(torrent.hash_string)

    return f"loaded:{len(tracker_hosts)}", IterationState(
        tracker_hosts_count=len(tracker_hosts),
        preferred_torrent_count=len(preferred_hashes),
        preferred_bootstrap_active=preferred_bootstrap_active,
        preferred_upload_active=preferred_upload_active,
        preferred_upload_bytes_per_second=preferred_upload_bytes_per_second,
        torrent_counts=torrent_counts,
        torrent_activity_counts=activity_counts,
        bandwidth_active_torrent_counts=bandwidth_counts,
        peer_counts=peer_counts,
        download_bytes_per_second=downloads,
        upload_bytes_per_second=uploads,
        high_priority_hashes=sorted(high),
        normal_priority_hashes=sorted(normal),
        low_priority_hashes=sorted(low),
        stop_hashes=sorted(stop),
    )


def apply_priority_updates(client: TorrentClient, state: IterationState) -> None:
    client.set_priority(state.high_priority_hashes, TR_PRI_HIGH)
    client.set_priority(state.normal_priority_hashes, TR_PRI_NORMAL)
    client.set_priority(state.low_priority_hashes, TR_PRI_LOW)
    client.stop(state.stop_hashes)


def _gauge(
    registry: CollectorRegistry,
    name: str,
    documentation: str,
    labelnames: Sequence[str] = (),
) -> Gauge:
    return Gauge(name, documentation, labelnames, registry=registry)


def health_registry(
    *,
    exporter_ok: bool,
    last_run_timestamp_seconds: float,
    last_success_timestamp_seconds: float | None,
    registry: CollectorRegistry | None = None,
) -> CollectorRegistry:
    result = registry or CollectorRegistry()
    _gauge(
        result,
        "host_observability_transmission_exporter_ok",
        "Whether the latest Transmission metrics collection iteration succeeded.",
    ).set(exporter_ok)
    _gauge(
        result,
        "host_observability_transmission_exporter_last_run_timestamp_seconds",
        "Unix timestamp when the latest Transmission metrics collection iteration completed.",
    ).set(last_run_timestamp_seconds)
    if last_success_timestamp_seconds is not None:
        _gauge(
            result,
            "host_observability_transmission_exporter_last_success_timestamp_seconds",
            "Unix timestamp when the latest successful iteration completed.",
        ).set(last_success_timestamp_seconds)
    return result


def success_registry(state: IterationState, timestamp: float) -> CollectorRegistry:
    registry = CollectorRegistry()
    torrent_count = _gauge(
        registry,
        "host_observability_transmission_torrent_count",
        "Number of Transmission torrents by torrent priority class.",
        ["class"],
    )
    activity_count = _gauge(
        registry,
        "host_observability_transmission_torrent_activity_count",
        "Number of Transmission torrents by transfer direction and activity state.",
        ["direction", "activity"],
    )
    bandwidth_count = _gauge(
        registry,
        "host_observability_transmission_bandwidth_active_torrent_count",
        "Number of active Transmission torrents by bandwidth direction and priority class.",
        ["direction", "class"],
    )
    peer_count = _gauge(
        registry,
        "host_observability_transmission_peer_count",
        "Number of Transmission peers by torrent priority class and relationship.",
        ["class", "state"],
    )
    download_rate = _gauge(
        registry,
        "host_observability_transmission_download_bytes_per_second",
        "Current aggregate download rate by torrent priority class.",
        ["class"],
    )
    upload_rate = _gauge(
        registry,
        "host_observability_transmission_upload_bytes_per_second",
        "Current aggregate upload rate by torrent priority class.",
        ["class"],
    )
    for torrent_class in PRIORITY_CLASSES:
        torrent_count.labels(torrent_class).set(state.torrent_counts[torrent_class])
        download_rate.labels(torrent_class).set(state.download_bytes_per_second[torrent_class])
        upload_rate.labels(torrent_class).set(state.upload_bytes_per_second[torrent_class])
        for peer_state in ("connected", "getting_from_us", "sending_to_us"):
            peer_count.labels(torrent_class, peer_state).set(
                state.peer_counts[torrent_class][peer_state]
            )
    for direction in ("seeding", "downloading"):
        for activity in ("active", "inactive"):
            activity_count.labels(direction, activity).set(
                state.torrent_activity_counts[direction][activity]
            )
    for direction in ("download", "upload"):
        for torrent_class in PRIORITY_CLASSES:
            bandwidth_count.labels(direction, torrent_class).set(
                state.bandwidth_active_torrent_counts[direction][torrent_class]
            )

    fair_share = _gauge(
        registry,
        "host_observability_transmission_bandwidth_fair_share_ratio",
        "Bandwidth share divided by the active-torrent equal-share baseline.",
        ["direction", "class"],
    )
    for direction, rates in (
        ("download", state.download_bytes_per_second),
        ("upload", state.upload_bytes_per_second),
    ):
        total_rate = sum(rates.values())
        total_active = sum(state.bandwidth_active_torrent_counts[direction].values())
        for torrent_class in PRIORITY_CLASSES:
            active = state.bandwidth_active_torrent_counts[direction][torrent_class]
            rate = rates[torrent_class]
            expected = total_rate * active / total_active if total_active else 0.0
            ratio = rate / expected if active and rate and expected else 1.0
            fair_share.labels(direction, torrent_class).set(ratio)

    scalar_metrics = (
        (
            "host_observability_transmission_preferred_upload_active",
            "Whether any preferred torrent is actively uploading to peers.",
            int(state.preferred_upload_active),
        ),
        (
            "host_observability_transmission_preferred_bootstrap_active",
            "Whether a preferred torrent has peers actively downloading from us.",
            int(state.preferred_bootstrap_active),
        ),
        (
            "host_observability_transmission_preferred_upload_bytes_per_second",
            "Current aggregate upload rate for preferred torrents.",
            state.preferred_upload_bytes_per_second,
        ),
        (
            "host_observability_transmission_reserved_private_upload_bytes_per_second",
            "Reserved upload capacity; retained as zero for dashboard compatibility.",
            0,
        ),
        (
            "host_observability_transmission_public_group_upload_limit_bytes_per_second",
            "Managed public upload cap; retained as zero for dashboard compatibility.",
            0,
        ),
        (
            "host_observability_transmission_observed_public_group_upload_limit_bytes_per_second",
            "Observed public upload cap; retained as zero for dashboard compatibility.",
            0,
        ),
    )
    for name, documentation, value in scalar_metrics:
        _gauge(registry, name, documentation).set(value)
    return health_registry(
        exporter_ok=True,
        last_run_timestamp_seconds=timestamp,
        last_success_timestamp_seconds=timestamp,
        registry=registry,
    )


def write_registry(path: Path, registry: CollectorRegistry) -> None:
    write_to_textfile(str(path), registry)
    os.chmod(path, 0o644)


def write_health_metrics(
    metrics_file: Path | None,
    *,
    exporter_ok: bool,
    last_run_timestamp_seconds: float,
    last_success_timestamp_seconds: float | None,
) -> None:
    if metrics_file is not None:
        write_registry(
            metrics_file,
            health_registry(
                exporter_ok=exporter_ok,
                last_run_timestamp_seconds=last_run_timestamp_seconds,
                last_success_timestamp_seconds=last_success_timestamp_seconds,
            ),
        )


def write_iteration_metrics(
    metrics_file: Path | None, state: IterationState, metrics_timestamp_seconds: float
) -> None:
    if metrics_file is not None:
        write_registry(metrics_file, success_registry(state, metrics_timestamp_seconds))


def add_common_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--rpc-url", default="http://127.0.0.1:9091/transmission/rpc")
    parser.add_argument("--trackers-file", required=True, type=Path)
    parser.add_argument(
        "--non-preferred-low-priority-ratio",
        type=float,
        default=DEFAULT_NON_PREFERRED_LOW_PRIORITY_RATIO_THRESHOLD,
    )
    parser.add_argument(
        "--non-preferred-pause-ratio",
        type=float,
        default=DEFAULT_NON_PREFERRED_PAUSE_RATIO_THRESHOLD,
    )
    parser.add_argument("--interval-seconds", type=float, default=60.0)
    parser.add_argument("--request-timeout-seconds", type=float, default=15.0)
    parser.add_argument(
        "--log-level",
        default="INFO",
        choices=["DEBUG", "INFO", "WARNING", "ERROR"],
    )


def settings_from_args(args: argparse.Namespace) -> DaemonSettings:
    return DaemonSettings(
        rpc_url=args.rpc_url,
        trackers_file=args.trackers_file,
        interval_seconds=args.interval_seconds,
        request_timeout_seconds=args.request_timeout_seconds,
        policy=Policy(
            non_preferred_low_priority_ratio_threshold=(args.non_preferred_low_priority_ratio),
            non_preferred_pause_ratio_threshold=args.non_preferred_pause_ratio,
        ),
    )


def build_client(settings: DaemonSettings) -> TransmissionClient:
    return TransmissionClient(
        TransmissionRpcClient(
            rpc_url=settings.rpc_url,
            timeout_seconds=settings.request_timeout_seconds,
        )
    )
