#!/usr/bin/env python3

import argparse
import json
import logging
import os
import socket
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path


LOG = logging.getLogger("transmission-tracker-prioritizer")
TR_PRI_LOW = -1
TR_PRI_NORMAL = 0
TR_PRI_HIGH = 1
PRIORITY_CLASSES = ("low", "normal", "high")
DEFAULT_NON_PREFERRED_LOW_PRIORITY_RATIO_THRESHOLD = 3.0


class TransmissionRpcError(RuntimeError):
    pass


class TransmissionRpcClient:
    def __init__(self, rpc_url: str, timeout_seconds: float) -> None:
        self.rpc_url = rpc_url
        self.timeout_seconds = timeout_seconds
        self.session_id: str | None = None

    def call(self, method: str, arguments: dict | None = None) -> dict:
        payload = json.dumps(
            {
                "method": method,
                "arguments": arguments or {},
            }
        ).encode("utf-8")

        for attempt in range(2):
            headers = {
                "Content-Type": "application/json",
            }
            if self.session_id is not None:
                headers["X-Transmission-Session-Id"] = self.session_id

            request = urllib.request.Request(
                self.rpc_url,
                data=payload,
                headers=headers,
                method="POST",
            )

            try:
                with urllib.request.urlopen(
                    request, timeout=self.timeout_seconds
                ) as response:
                    body = response.read().decode("utf-8")
            except urllib.error.HTTPError as exc:
                if exc.code == 409 and attempt == 0:
                    session_id = exc.headers.get("X-Transmission-Session-Id")
                    if session_id:
                        self.session_id = session_id
                        continue
                raise TransmissionRpcError(
                    f"HTTP {exc.code} from Transmission RPC"
                ) from exc
            except (TimeoutError, socket.timeout, urllib.error.URLError) as exc:
                raise TransmissionRpcError(
                    f"request to Transmission RPC failed: {exc}"
                ) from exc

            try:
                parsed = json.loads(body)
            except json.JSONDecodeError as exc:
                raise TransmissionRpcError(
                    "Transmission RPC returned invalid JSON"
                ) from exc

            result = parsed.get("result")
            if result != "success":
                raise TransmissionRpcError(f"Transmission RPC returned {result!r}")

            return parsed.get("arguments", {})

        raise TransmissionRpcError("failed to negotiate Transmission session id")


def normalize_tracker_host(raw_value: str) -> str:
    value = raw_value.strip()
    if not value:
        return ""

    if "://" in value:
        parsed = urllib.parse.urlparse(value)
        return (parsed.hostname or "").lower()

    if value.startswith("[") and "]" in value:
        return value[1 : value.index("]")].lower()

    value = value.rsplit("@", 1)[-1]
    value = value.split("/", 1)[0]
    value = value.split(":", 1)[0]
    return value.lower()


def load_tracker_hosts(trackers_file: Path) -> set[str] | None:
    if not trackers_file.exists():
        return None

    try:
        lines = trackers_file.read_text().splitlines()
    except OSError as exc:
        LOG.warning("unable to read tracker host file %s: %s", trackers_file, exc)
        return None

    hosts: set[str] = set()
    for line_number, raw_line in enumerate(lines, start=1):
        line = raw_line.split("#", 1)[0].strip()
        if not line:
            continue

        host = normalize_tracker_host(line)
        if not host:
            LOG.warning("ignoring empty tracker host entry on line %s", line_number)
            continue
        hosts.add(host)

    return hosts


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


def torrent_desired_priority(
    torrent: dict,
    is_preferred: bool,
    non_preferred_low_priority_ratio_threshold: float,
) -> int:
    if is_preferred:
        return TR_PRI_HIGH

    left_until_done = torrent.get("leftUntilDone")
    is_complete = isinstance(left_until_done, int) and left_until_done <= 0
    if not is_complete:
        return TR_PRI_NORMAL

    upload_ratio = torrent.get("uploadRatio")
    if (
        isinstance(upload_ratio, (int, float))
        and upload_ratio >= non_preferred_low_priority_ratio_threshold
    ):
        return TR_PRI_LOW

    return TR_PRI_NORMAL


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
            "# HELP host_observability_transmission_bandwidth_fair_share_ratio Current bandwidth share for a torrent priority class divided by the equal-share baseline implied by that class's count of active torrents in the same direction.",
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
            expected_bytes_per_second = 0.0
            if total_active_torrent_count > 0:
                expected_bytes_per_second = (
                    total_bytes_per_second
                    * active_torrent_count
                    / total_active_torrent_count
                )
            fair_share_ratio = 0.0
            if expected_bytes_per_second > 0:
                fair_share_ratio = (
                    bytes_per_second_by_class[torrent_class] / expected_bytes_per_second
                )
            lines.append(
                f'host_observability_transmission_bandwidth_fair_share_ratio{{direction="{direction}",class="{torrent_class}"}} {fair_share_ratio}'
            )

    lines.extend(
        [
            "# HELP host_observability_transmission_preferred_upload_active Whether any preferred torrent is actively uploading to peers.",
            "# TYPE host_observability_transmission_preferred_upload_active gauge",
            f"host_observability_transmission_preferred_upload_active {1 if preferred_upload_active else 0}",
            "# HELP host_observability_transmission_preferred_bootstrap_active Whether any preferred torrent currently has connected peers and therefore qualifies for bootstrap private headroom.",
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


def torrent_matches_tracker_hosts(torrent: dict, tracker_hosts: set[str]) -> bool:
    for tracker in torrent.get("trackerStats", []):
        if not isinstance(tracker, dict):
            continue
        host = normalize_tracker_host(str(tracker.get("host", "")))
        if host and host in tracker_hosts:
            return True

        announce = tracker.get("announce")
        if isinstance(announce, str):
            host = normalize_tracker_host(announce)
            if host and host in tracker_hosts:
                return True

    return False


def rpc_get_torrents(client: TransmissionRpcClient) -> list[dict]:
    arguments = client.call(
        "torrent-get",
        {
            "fields": [
                "id",
                "name",
                "hashString",
                "bandwidthPriority",
                "peersConnected",
                "peersGettingFromUs",
                "peersSendingToUs",
                "leftUntilDone",
                "uploadRatio",
                "rateDownload",
                "rateUpload",
                "trackerStats",
            ]
        },
    )
    torrents = arguments.get("torrents", [])
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

    arguments = {
        "ids": torrent_hashes,
    }
    arguments.update(fields)
    client.call(
        "torrent-set",
        arguments,
    )


def run_iteration(
    client: TransmissionRpcClient,
    trackers_file: Path,
    metrics_file: Path | None,
    last_tracker_status: str | None,
    non_preferred_low_priority_ratio_threshold: float,
    metrics_timestamp_seconds: float,
) -> tuple[str | None, bool]:
    tracker_hosts = load_tracker_hosts(trackers_file)
    if tracker_hosts is None:
        status = f"missing:{trackers_file}"
        if status != last_tracker_status:
            LOG.warning(
                "tracker host file %s does not exist yet; skipping until it is created",
                trackers_file,
            )
        return status, False

    torrents = rpc_get_torrents(client)
    current_preferred_hashes: set[str] = set()
    preferred_upload_observed_active = False
    preferred_bootstrap_active = False
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
    to_prefer: list[str] = []
    to_make_normal_priority: list[str] = []
    to_make_low_priority: list[str] = []

    for torrent in torrents:
        torrent_hash = torrent.get("hashString")
        if not isinstance(torrent_hash, str) or not torrent_hash:
            continue

        is_preferred = torrent_matches_tracker_hosts(torrent, tracker_hosts)
        priority = torrent.get("bandwidthPriority")
        current_priority = priority if isinstance(priority, int) else TR_PRI_NORMAL
        torrent_class = priority_class_name(current_priority)
        torrent_counts[torrent_class] += 1
        peer_counts[torrent_class]["connected"] += nonnegative_int(
            torrent.get("peersConnected")
        )
        peer_counts[torrent_class]["getting_from_us"] += nonnegative_int(
            torrent.get("peersGettingFromUs")
        )
        peer_counts[torrent_class]["sending_to_us"] += nonnegative_int(
            torrent.get("peersSendingToUs")
        )
        download_bytes_per_second[torrent_class] += nonnegative_int(
            torrent.get("rateDownload")
        )
        upload_bytes_per_second[torrent_class] += nonnegative_int(
            torrent.get("rateUpload")
        )
        left_until_done = torrent.get("leftUntilDone")
        peers_getting_from_us = torrent.get("peersGettingFromUs")
        peers_sending_to_us = torrent.get("peersSendingToUs")
        rate_download = torrent.get("rateDownload")
        rate_upload = torrent.get("rateUpload")
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
        desired_priority = torrent_desired_priority(
            torrent,
            is_preferred,
            non_preferred_low_priority_ratio_threshold,
        )
        if is_preferred:
            current_preferred_hashes.add(torrent_hash)
            if isinstance(rate_upload, int) and rate_upload > 0:
                preferred_upload_bytes_per_second += rate_upload
            if (
                isinstance(torrent.get("peersConnected"), int)
                and torrent["peersConnected"] > 0
            ):
                preferred_bootstrap_active = True
            if (
                isinstance(peers_getting_from_us, int) and peers_getting_from_us > 0
            ) or (isinstance(rate_upload, int) and rate_upload > 0):
                preferred_upload_observed_active = True
            if current_priority != desired_priority:
                to_prefer.append(torrent_hash)
            continue

        if desired_priority == TR_PRI_NORMAL and current_priority != TR_PRI_NORMAL:
            to_make_normal_priority.append(torrent_hash)
            continue

        if desired_priority == TR_PRI_LOW and current_priority != TR_PRI_LOW:
            to_make_low_priority.append(torrent_hash)

    preferred_upload_active = preferred_upload_observed_active

    rpc_set_torrent_fields(
        client,
        sorted(to_prefer),
        {
            "bandwidthPriority": TR_PRI_HIGH,
        },
    )
    normal_fields = {
        "bandwidthPriority": TR_PRI_NORMAL,
    }
    rpc_set_torrent_fields(client, sorted(to_make_normal_priority), normal_fields)
    low_priority_fields = {
        "bandwidthPriority": TR_PRI_LOW,
    }
    rpc_set_torrent_fields(client, sorted(to_make_low_priority), low_priority_fields)

    if metrics_file is not None:
        write_text_atomic(
            metrics_file,
            render_metrics_text(
                torrent_counts=torrent_counts,
                torrent_activity_counts=torrent_activity_counts,
                bandwidth_active_torrent_counts=bandwidth_active_torrent_counts,
                peer_counts=peer_counts,
                download_bytes_per_second=download_bytes_per_second,
                upload_bytes_per_second=upload_bytes_per_second,
                preferred_bootstrap_active=preferred_bootstrap_active,
                preferred_upload_active=preferred_upload_active,
                preferred_upload_bytes_per_second=preferred_upload_bytes_per_second,
                last_run_timestamp_seconds=metrics_timestamp_seconds,
                last_success_timestamp_seconds=metrics_timestamp_seconds,
            ),
        )

    LOG.info(
        "iteration complete: tracker_hosts=%s preferred_torrents=%s preferred_bootstrap_active=%s preferred_upload_active=%s preferred_upload_bytes_per_second=%s preferred_updates=%s normal_priority_updates=%s low_priority_updates=%s",
        len(tracker_hosts),
        len(current_preferred_hashes),
        preferred_bootstrap_active,
        preferred_upload_active,
        preferred_upload_bytes_per_second,
        len(to_prefer),
        len(to_make_normal_priority),
        len(to_make_low_priority),
    )
    return f"loaded:{len(tracker_hosts)}", True


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Continuously raise Transmission bandwidth priority for torrents on selected trackers.",
    )
    parser.add_argument(
        "--rpc-url",
        default="http://127.0.0.1:9091/transmission/rpc",
        help="Transmission RPC URL.",
    )
    parser.add_argument(
        "--trackers-file",
        required=True,
        help="Path to a file containing one tracker host or announce URL per line.",
    )
    parser.add_argument(
        "--non-preferred-low-priority-ratio",
        type=float,
        default=DEFAULT_NON_PREFERRED_LOW_PRIORITY_RATIO_THRESHOLD,
        help="Upload ratio at which completed non-preferred torrents are demoted to low priority.",
    )
    parser.add_argument(
        "--interval-seconds",
        type=float,
        default=60.0,
        help="Delay between iterations.",
    )
    parser.add_argument(
        "--request-timeout-seconds",
        type=float,
        default=15.0,
        help="Per-request timeout when talking to Transmission.",
    )
    parser.add_argument(
        "--metrics-file",
        default="",
        help="Optional Prometheus textfile path for exported torrent priority metrics.",
    )
    parser.add_argument(
        "--log-level",
        default="INFO",
        choices=["DEBUG", "INFO", "WARNING", "ERROR"],
        help="Logging verbosity.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    logging.basicConfig(
        level=getattr(logging, args.log_level),
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )

    client = TransmissionRpcClient(
        rpc_url=args.rpc_url,
        timeout_seconds=args.request_timeout_seconds,
    )
    trackers_file = Path(args.trackers_file)
    metrics_file = Path(args.metrics_file.strip())
    if args.metrics_file.strip() == "":
        metrics_file = None
    last_tracker_status: str | None = None
    last_success_timestamp_seconds: float | None = None

    while True:
        started_at = time.monotonic()
        iteration_timestamp_seconds = time.time()
        iteration_succeeded = False
        try:
            last_tracker_status, iteration_succeeded = run_iteration(
                client=client,
                trackers_file=trackers_file,
                metrics_file=metrics_file,
                last_tracker_status=last_tracker_status,
                non_preferred_low_priority_ratio_threshold=args.non_preferred_low_priority_ratio,
                metrics_timestamp_seconds=iteration_timestamp_seconds,
            )
        except TransmissionRpcError as exc:
            LOG.warning("skipping iteration after Transmission RPC failure: %s", exc)
        except Exception:
            LOG.exception("skipping iteration after unexpected failure")
        if iteration_succeeded:
            last_success_timestamp_seconds = iteration_timestamp_seconds
        else:
            write_health_metrics(
                metrics_file,
                exporter_ok=False,
                last_run_timestamp_seconds=iteration_timestamp_seconds,
                last_success_timestamp_seconds=last_success_timestamp_seconds,
            )

        sleep_for = max(0.0, args.interval_seconds - (time.monotonic() - started_at))
        time.sleep(sleep_for)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("", file=sys.stderr)
        raise SystemExit(0)
