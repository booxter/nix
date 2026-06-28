from dataclasses import dataclass
import logging
import os
import tempfile
from pathlib import Path

from transmission_common.transmission import (
    TransmissionRpcClient,
    TransmissionRpcError,
    read_tracker_hosts,
    torrent_matches_tracker_hosts,
)


LOG = logging.getLogger("transmission-tracker-common")
TR_PRI_LOW = -1
TR_PRI_NORMAL = 0
TR_PRI_HIGH = 1
TR_STATUS_STOPPED = 0
PRIORITY_CLASSES = ("low", "normal", "high")
DEFAULT_NON_PREFERRED_LOW_PRIORITY_RATIO_THRESHOLD = 3.0
DEFAULT_NON_PREFERRED_PAUSE_RATIO_THRESHOLD = 6.0


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


def write_text_atomic(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_path = tempfile.mkstemp(dir=str(path.parent), prefix=f".{path.name}.")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(content)
        os.chmod(tmp_path, 0o644)
        os.replace(tmp_path, path)
    except Exception:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


def nonnegative_int(value: object) -> int:
    return value if isinstance(value, int) and value >= 0 else 0


def priority_class_name(priority: int) -> str:
    if priority <= TR_PRI_LOW:
        return "low"
    if priority >= TR_PRI_HIGH:
        return "high"
    return "normal"


def torrent_is_complete(torrent: dict) -> bool:
    left_until_done = torrent.get("left_until_done")
    return isinstance(left_until_done, int) and left_until_done == 0


def torrent_desired_priority(
    torrent: dict,
    is_preferred: bool,
    preferred_bootstrap_active: bool,
    non_preferred_low_priority_ratio_threshold: float,
) -> int:
    if is_preferred:
        return TR_PRI_HIGH

    upload_ratio = torrent.get("upload_ratio")
    baseline_non_preferred_priority = TR_PRI_NORMAL
    if (
        isinstance(upload_ratio, (int, float))
        and upload_ratio >= non_preferred_low_priority_ratio_threshold
    ):
        baseline_non_preferred_priority = TR_PRI_LOW

    if preferred_bootstrap_active:
        return baseline_non_preferred_priority

    if baseline_non_preferred_priority == TR_PRI_NORMAL:
        return TR_PRI_HIGH

    return TR_PRI_LOW


def render_metrics_text(
    *,
    torrent_counts: dict[str, int],
    torrent_activity_counts: dict[str, dict[str, int]],
    bandwidth_active_torrent_counts: dict[str, dict[str, int]],
    peer_counts: dict[str, dict[str, int]],
    download_bytes_per_second: dict[str, int],
    upload_bytes_per_second: dict[str, int],
    preferred_bootstrap_active: bool,
    preferred_upload_active: bool,
    preferred_upload_bytes_per_second: int,
    last_run_timestamp_seconds: float,
    last_success_timestamp_seconds: float | None,
) -> str:
    total_bandwidth_active_torrent_counts = {
        direction: sum(active_counts.values())
        for direction, active_counts in bandwidth_active_torrent_counts.items()
    }
    total_bytes_per_second_by_direction = {
        "download": sum(download_bytes_per_second.values()),
        "upload": sum(upload_bytes_per_second.values()),
    }
    lines = [
        "# HELP host_observability_transmission_torrent_count Number of Transmission torrents by torrent priority class.",
        "# TYPE host_observability_transmission_torrent_count gauge",
    ]
    for torrent_class in PRIORITY_CLASSES:
        lines.append(
            f'host_observability_transmission_torrent_count{{class="{torrent_class}"}} {torrent_counts[torrent_class]}'
        )

    lines.extend(
        [
            "# HELP host_observability_transmission_torrent_activity_count Number of Transmission torrents by transfer direction and activity state.",
            "# TYPE host_observability_transmission_torrent_activity_count gauge",
        ]
    )
    for direction in ("seeding", "downloading"):
        for activity in ("active", "inactive"):
            lines.append(
                f'host_observability_transmission_torrent_activity_count{{direction="{direction}",activity="{activity}"}} {torrent_activity_counts[direction][activity]}'
            )

    lines.extend(
        [
            "# HELP host_observability_transmission_bandwidth_active_torrent_count Number of Transmission torrents by torrent priority class currently active in the given bandwidth direction.",
            "# TYPE host_observability_transmission_bandwidth_active_torrent_count gauge",
        ]
    )
    for direction in ("download", "upload"):
        for torrent_class in PRIORITY_CLASSES:
            lines.append(
                f'host_observability_transmission_bandwidth_active_torrent_count{{direction="{direction}",class="{torrent_class}"}} {bandwidth_active_torrent_counts[direction][torrent_class]}'
            )

    lines.extend(
        [
            "# HELP host_observability_transmission_peer_count Number of Transmission peers by torrent priority class and relationship.",
            "# TYPE host_observability_transmission_peer_count gauge",
        ]
    )
    for torrent_class in PRIORITY_CLASSES:
        for state in ("connected", "getting_from_us", "sending_to_us"):
            lines.append(
                f'host_observability_transmission_peer_count{{class="{torrent_class}",state="{state}"}} {peer_counts[torrent_class][state]}'
            )

    lines.extend(
        [
            "# HELP host_observability_transmission_download_bytes_per_second Current aggregate download rate for Transmission torrents by torrent priority class.",
            "# TYPE host_observability_transmission_download_bytes_per_second gauge",
        ]
    )
    for torrent_class in PRIORITY_CLASSES:
        lines.append(
            f'host_observability_transmission_download_bytes_per_second{{class="{torrent_class}"}} {download_bytes_per_second[torrent_class]}'
        )

    lines.extend(
        [
            "# HELP host_observability_transmission_upload_bytes_per_second Current aggregate upload rate for Transmission torrents by torrent priority class.",
            "# TYPE host_observability_transmission_upload_bytes_per_second gauge",
        ]
    )
    for torrent_class in PRIORITY_CLASSES:
        lines.append(
            f'host_observability_transmission_upload_bytes_per_second{{class="{torrent_class}"}} {upload_bytes_per_second[torrent_class]}'
        )

    lines.extend(
        [
            "# HELP host_observability_transmission_bandwidth_fair_share_ratio Current bandwidth share for a torrent priority class divided by the equal-share baseline implied by that class's count of active torrents in the same direction. Classes with no active torrents or no observed bandwidth in that direction export 1.0 as the neutral baseline.",
            "# TYPE host_observability_transmission_bandwidth_fair_share_ratio gauge",
        ]
    )
    for direction in ("download", "upload"):
        total_bytes_per_second = total_bytes_per_second_by_direction[direction]
        total_active_torrent_count = total_bandwidth_active_torrent_counts[direction]
        bytes_per_second_by_class = (
            download_bytes_per_second
            if direction == "download"
            else upload_bytes_per_second
        )
        for torrent_class in PRIORITY_CLASSES:
            active_torrent_count = bandwidth_active_torrent_counts[direction][
                torrent_class
            ]
            actual_bytes_per_second = bytes_per_second_by_class[torrent_class]
            if active_torrent_count == 0 or actual_bytes_per_second == 0:
                lines.append(
                    f'host_observability_transmission_bandwidth_fair_share_ratio{{direction="{direction}",class="{torrent_class}"}} 1.0'
                )
                continue
            expected_bytes_per_second = 0.0
            if total_active_torrent_count > 0:
                expected_bytes_per_second = (
                    total_bytes_per_second
                    * active_torrent_count
                    / total_active_torrent_count
                )
            fair_share_ratio = 0.0
            if expected_bytes_per_second > 0:
                fair_share_ratio = actual_bytes_per_second / expected_bytes_per_second
            lines.append(
                f'host_observability_transmission_bandwidth_fair_share_ratio{{direction="{direction}",class="{torrent_class}"}} {fair_share_ratio}'
            )

    lines.extend(
        [
            "# HELP host_observability_transmission_preferred_upload_active Whether any preferred torrent is actively uploading to peers.",
            "# TYPE host_observability_transmission_preferred_upload_active gauge",
            f"host_observability_transmission_preferred_upload_active {1 if preferred_upload_active else 0}",
            "# HELP host_observability_transmission_preferred_bootstrap_active Whether any preferred torrent currently has peers actively downloading from us and therefore qualifies for bootstrap private headroom.",
            "# TYPE host_observability_transmission_preferred_bootstrap_active gauge",
            f"host_observability_transmission_preferred_bootstrap_active {1 if preferred_bootstrap_active else 0}",
            "# HELP host_observability_transmission_preferred_upload_bytes_per_second Current aggregate upload rate for preferred torrents.",
            "# TYPE host_observability_transmission_preferred_upload_bytes_per_second gauge",
            f"host_observability_transmission_preferred_upload_bytes_per_second {preferred_upload_bytes_per_second}",
            "# HELP host_observability_transmission_reserved_private_upload_bytes_per_second Reserved session upload capacity currently held for preferred torrents by the public-group cap policy. This service no longer manages that cap and therefore exports zero.",
            "# TYPE host_observability_transmission_reserved_private_upload_bytes_per_second gauge",
            "host_observability_transmission_reserved_private_upload_bytes_per_second 0",
            "# HELP host_observability_transmission_public_group_upload_limit_bytes_per_second Effective upload cap for the managed public torrent group. This service no longer manages that cap and therefore exports zero.",
            "# TYPE host_observability_transmission_public_group_upload_limit_bytes_per_second gauge",
            "host_observability_transmission_public_group_upload_limit_bytes_per_second 0",
            "# HELP host_observability_transmission_observed_public_group_upload_limit_bytes_per_second Throughput-derived observed upload cap for the managed public torrent group before hysteresis is applied. This service no longer manages that cap and therefore exports zero.",
            "# TYPE host_observability_transmission_observed_public_group_upload_limit_bytes_per_second gauge",
            "host_observability_transmission_observed_public_group_upload_limit_bytes_per_second 0",
        ]
    )
    lines.extend(
        health_metrics_lines(
            exporter_ok=True,
            last_run_timestamp_seconds=last_run_timestamp_seconds,
            last_success_timestamp_seconds=last_success_timestamp_seconds,
        )
    )
    return "\n".join(lines) + "\n"


def health_metrics_lines(
    *,
    exporter_ok: bool,
    last_run_timestamp_seconds: float,
    last_success_timestamp_seconds: float | None,
) -> list[str]:
    lines = [
        "# HELP host_observability_transmission_exporter_ok Whether the latest Transmission metrics collection iteration succeeded.",
        "# TYPE host_observability_transmission_exporter_ok gauge",
        f"host_observability_transmission_exporter_ok {1 if exporter_ok else 0}",
        "# HELP host_observability_transmission_exporter_last_run_timestamp_seconds Unix timestamp when the latest Transmission metrics collection iteration completed.",
        "# TYPE host_observability_transmission_exporter_last_run_timestamp_seconds gauge",
        f"host_observability_transmission_exporter_last_run_timestamp_seconds {last_run_timestamp_seconds}",
    ]
    if last_success_timestamp_seconds is not None:
        lines.extend(
            [
                "# HELP host_observability_transmission_exporter_last_success_timestamp_seconds Unix timestamp when the latest successful Transmission metrics collection iteration completed.",
                "# TYPE host_observability_transmission_exporter_last_success_timestamp_seconds gauge",
                f"host_observability_transmission_exporter_last_success_timestamp_seconds {last_success_timestamp_seconds}",
            ]
        )
    return lines


def render_health_metrics_text(
    *,
    exporter_ok: bool,
    last_run_timestamp_seconds: float,
    last_success_timestamp_seconds: float | None,
) -> str:
    return (
        "\n".join(
            health_metrics_lines(
                exporter_ok=exporter_ok,
                last_run_timestamp_seconds=last_run_timestamp_seconds,
                last_success_timestamp_seconds=last_success_timestamp_seconds,
            )
        )
        + "\n"
    )


def write_health_metrics(
    metrics_file: Path | None,
    *,
    exporter_ok: bool,
    last_run_timestamp_seconds: float,
    last_success_timestamp_seconds: float | None,
) -> None:
    if metrics_file is None:
        return
    write_text_atomic(
        metrics_file,
        render_health_metrics_text(
            exporter_ok=exporter_ok,
            last_run_timestamp_seconds=last_run_timestamp_seconds,
            last_success_timestamp_seconds=last_success_timestamp_seconds,
        ),
    )


def rpc_get_torrents(client: TransmissionRpcClient) -> list[dict]:
    result = client.call(
        "torrent_get",
        {
            "fields": [
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
        },
    )
    torrents = result.get("torrents", [])
    if not isinstance(torrents, list):
        raise TransmissionRpcError("Transmission RPC returned an invalid torrent list")
    return torrents


def rpc_set_torrent_fields(
    client: TransmissionRpcClient,
    torrent_hashes: list[str],
    fields: dict,
) -> None:
    if not torrent_hashes or not fields:
        return

    params = {
        "ids": torrent_hashes,
    }
    params.update(fields)
    client.call(
        "torrent_set",
        params,
    )


def rpc_stop_torrents(client: TransmissionRpcClient, torrent_hashes: list[str]) -> None:
    if not torrent_hashes:
        return

    client.call(
        "torrent_stop",
        {
            "ids": torrent_hashes,
        },
    )


@dataclass
class IterationState:
    tracker_hosts_count: int
    preferred_torrent_count: int
    preferred_bootstrap_active: bool
    preferred_upload_active: bool
    preferred_upload_bytes_per_second: int
    torrent_counts: dict[str, int]
    torrent_activity_counts: dict[str, dict[str, int]]
    bandwidth_active_torrent_counts: dict[str, dict[str, int]]
    peer_counts: dict[str, dict[str, int]]
    download_bytes_per_second: dict[str, int]
    upload_bytes_per_second: dict[str, int]
    high_priority_hashes: list[str]
    normal_priority_hashes: list[str]
    low_priority_hashes: list[str]
    stop_hashes: list[str]


def collect_iteration_state(
    client: TransmissionRpcClient,
    trackers_file: Path,
    last_tracker_status: str | None,
    non_preferred_low_priority_ratio_threshold: float,
    non_preferred_pause_ratio_threshold: float,
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

    torrents = rpc_get_torrents(client)
    torrent_entries: list[tuple[dict, str, bool]] = []
    current_preferred_hashes: set[str] = set()
    for torrent in torrents:
        torrent_hash = torrent.get("hash_string")
        if not isinstance(torrent_hash, str) or not torrent_hash:
            continue
        is_preferred = torrent_matches_tracker_hosts(torrent, tracker_hosts)
        if is_preferred:
            current_preferred_hashes.add(torrent_hash)
        torrent_entries.append((torrent, torrent_hash, is_preferred))

    preferred_bootstrap_active = any(
        is_preferred
        and isinstance(torrent.get("peers_getting_from_us"), int)
        and torrent["peers_getting_from_us"] > 0
        for torrent, _torrent_hash, is_preferred in torrent_entries
    )
    preferred_upload_observed_active = False
    preferred_upload_bytes_per_second = 0
    torrent_counts = {torrent_class: 0 for torrent_class in PRIORITY_CLASSES}
    torrent_activity_counts = {
        "seeding": {
            "active": 0,
            "inactive": 0,
        },
        "downloading": {
            "active": 0,
            "inactive": 0,
        },
    }
    bandwidth_active_torrent_counts = {
        direction: {torrent_class: 0 for torrent_class in PRIORITY_CLASSES}
        for direction in ("download", "upload")
    }
    peer_counts = {
        torrent_class: {
            "connected": 0,
            "getting_from_us": 0,
            "sending_to_us": 0,
        }
        for torrent_class in PRIORITY_CLASSES
    }
    upload_bytes_per_second = {torrent_class: 0 for torrent_class in PRIORITY_CLASSES}
    download_bytes_per_second = {torrent_class: 0 for torrent_class in PRIORITY_CLASSES}
    to_make_high_priority: list[str] = []
    to_make_normal_priority: list[str] = []
    to_make_low_priority: list[str] = []
    to_stop: list[str] = []

    for torrent, torrent_hash, is_preferred in torrent_entries:
        priority = torrent.get("bandwidth_priority")
        current_priority = priority if isinstance(priority, int) else TR_PRI_NORMAL
        status = torrent.get("status")
        current_status = status if isinstance(status, int) else None
        torrent_class = priority_class_name(current_priority)
        torrent_counts[torrent_class] += 1
        peer_counts[torrent_class]["connected"] += nonnegative_int(
            torrent.get("peers_connected")
        )
        peer_counts[torrent_class]["getting_from_us"] += nonnegative_int(
            torrent.get("peers_getting_from_us")
        )
        peer_counts[torrent_class]["sending_to_us"] += nonnegative_int(
            torrent.get("peers_sending_to_us")
        )
        download_bytes_per_second[torrent_class] += nonnegative_int(
            torrent.get("rate_download")
        )
        upload_bytes_per_second[torrent_class] += nonnegative_int(
            torrent.get("rate_upload")
        )
        left_until_done = torrent.get("left_until_done")
        peers_getting_from_us = torrent.get("peers_getting_from_us")
        peers_sending_to_us = torrent.get("peers_sending_to_us")
        rate_download = torrent.get("rate_download")
        rate_upload = torrent.get("rate_upload")
        upload_ratio = torrent.get("upload_ratio")
        is_active_download = (
            isinstance(peers_sending_to_us, int) and peers_sending_to_us > 0
        ) or (isinstance(rate_download, int) and rate_download > 0)
        is_active_upload = (
            isinstance(peers_getting_from_us, int) and peers_getting_from_us > 0
        ) or (isinstance(rate_upload, int) and rate_upload > 0)
        if is_active_download:
            bandwidth_active_torrent_counts["download"][torrent_class] += 1
        if is_active_upload:
            bandwidth_active_torrent_counts["upload"][torrent_class] += 1
        if isinstance(left_until_done, int):
            if left_until_done > 0:
                torrent_activity_counts["downloading"][
                    "active" if is_active_download else "inactive"
                ] += 1
            else:
                torrent_activity_counts["seeding"][
                    "active" if is_active_upload else "inactive"
                ] += 1
        if (
            not is_preferred
            and torrent_is_complete(torrent)
            and isinstance(upload_ratio, (int, float))
            and upload_ratio >= non_preferred_pause_ratio_threshold
            and current_status != TR_STATUS_STOPPED
        ):
            to_stop.append(torrent_hash)
        desired_priority = torrent_desired_priority(
            torrent,
            is_preferred,
            preferred_bootstrap_active,
            non_preferred_low_priority_ratio_threshold,
        )
        if is_preferred:
            if isinstance(rate_upload, int) and rate_upload > 0:
                preferred_upload_bytes_per_second += rate_upload
            if isinstance(peers_getting_from_us, int) and peers_getting_from_us > 0:
                preferred_upload_observed_active = True

        if desired_priority == TR_PRI_HIGH and current_priority != TR_PRI_HIGH:
            to_make_high_priority.append(torrent_hash)
            continue

        if desired_priority == TR_PRI_NORMAL and current_priority != TR_PRI_NORMAL:
            to_make_normal_priority.append(torrent_hash)
            continue

        if desired_priority == TR_PRI_LOW and current_priority != TR_PRI_LOW:
            to_make_low_priority.append(torrent_hash)

    return f"loaded:{len(tracker_hosts)}", IterationState(
        tracker_hosts_count=len(tracker_hosts),
        preferred_torrent_count=len(current_preferred_hashes),
        preferred_bootstrap_active=preferred_bootstrap_active,
        preferred_upload_active=preferred_upload_observed_active,
        preferred_upload_bytes_per_second=preferred_upload_bytes_per_second,
        torrent_counts=torrent_counts,
        torrent_activity_counts=torrent_activity_counts,
        bandwidth_active_torrent_counts=bandwidth_active_torrent_counts,
        peer_counts=peer_counts,
        download_bytes_per_second=download_bytes_per_second,
        upload_bytes_per_second=upload_bytes_per_second,
        high_priority_hashes=sorted(to_make_high_priority),
        normal_priority_hashes=sorted(to_make_normal_priority),
        low_priority_hashes=sorted(to_make_low_priority),
        stop_hashes=sorted(to_stop),
    )


def apply_priority_updates(
    client: TransmissionRpcClient,
    state: IterationState,
) -> None:
    rpc_set_torrent_fields(
        client,
        state.high_priority_hashes,
        {
            "bandwidth_priority": TR_PRI_HIGH,
        },
    )
    rpc_set_torrent_fields(
        client,
        state.normal_priority_hashes,
        {
            "bandwidth_priority": TR_PRI_NORMAL,
        },
    )
    rpc_set_torrent_fields(
        client,
        state.low_priority_hashes,
        {
            "bandwidth_priority": TR_PRI_LOW,
        },
    )
    rpc_stop_torrents(client, state.stop_hashes)


def write_iteration_metrics(
    metrics_file: Path | None,
    state: IterationState,
    metrics_timestamp_seconds: float,
) -> None:
    if metrics_file is None:
        return
    write_text_atomic(
        metrics_file,
        render_metrics_text(
            torrent_counts=state.torrent_counts,
            torrent_activity_counts=state.torrent_activity_counts,
            bandwidth_active_torrent_counts=state.bandwidth_active_torrent_counts,
            peer_counts=state.peer_counts,
            download_bytes_per_second=state.download_bytes_per_second,
            upload_bytes_per_second=state.upload_bytes_per_second,
            preferred_bootstrap_active=state.preferred_bootstrap_active,
            preferred_upload_active=state.preferred_upload_active,
            preferred_upload_bytes_per_second=state.preferred_upload_bytes_per_second,
            last_run_timestamp_seconds=metrics_timestamp_seconds,
            last_success_timestamp_seconds=metrics_timestamp_seconds,
        ),
    )
