#!/usr/bin/env python3

import argparse
import json
import logging
import math
import os
import re
import socket
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path


LOG = logging.getLogger("transmission-tracker-prioritizer")
TR_PRI_NORMAL = 0
TR_PRI_HIGH = 1
PROMETHEUS_SAMPLE_RE_TEMPLATE = (
    r"^{metric}(?:\{{(?P<labels>.*)\}})?\s+"
    r"(?P<value>[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?)"
    r"(?:\s+\d+)?$"
)
LABEL_PAIR_RE = re.compile(r'([A-Za-z_][A-Za-z0-9_]*)="((?:[^"\\]|\\.)*)"')
SABNZBD_PAUSED_METRIC_RE = re.compile(
    PROMETHEUS_SAMPLE_RE_TEMPLATE.format(metric="sabnzbd_paused")
)
SABNZBD_QUEUE_SIZE_METRIC_RE = re.compile(
    PROMETHEUS_SAMPLE_RE_TEMPLATE.format(metric="sabnzbd_queue_size")
)
SABNZBD_QUEUE_DOWNLOAD_RATE_METRIC_RE = re.compile(
    PROMETHEUS_SAMPLE_RE_TEMPLATE.format(
        metric="sabnzbd_queue_download_rate_bytes_per_second"
    )
)


class TransmissionRpcError(RuntimeError):
    pass


class ExporterError(RuntimeError):
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


def decode_prometheus_label_value(value: str) -> str:
    return (
        value.replace(r"\\", "\\")
        .replace(r"\"", '"')
        .replace(r"\n", "\n")
        .replace(r"\t", "\t")
    )


def parse_prometheus_labels(label_text: str) -> dict[str, str]:
    labels: dict[str, str] = {}
    for match in LABEL_PAIR_RE.finditer(label_text):
        labels[match.group(1)] = decode_prometheus_label_value(match.group(2))
    return labels


def fetch_url_text(url: str, timeout_seconds: float) -> str:
    request = urllib.request.Request(url, method="GET")
    try:
        with urllib.request.urlopen(request, timeout=timeout_seconds) as response:
            return response.read().decode("utf-8")
    except (TimeoutError, socket.timeout, urllib.error.URLError) as exc:
        raise ExporterError(f"request to exporter failed: {exc}") from exc


def parse_prometheus_metric_value(
    metric_re: re.Pattern[str],
    text: str,
    required_labels: dict[str, str] | None = None,
) -> float | None:
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        match = metric_re.match(line)
        if match is None:
            continue
        label_text = match.group("labels") or ""
        labels = parse_prometheus_labels(label_text)
        if required_labels is not None and any(
            labels.get(key) != value for key, value in required_labels.items()
        ):
            continue
        try:
            return float(match.group("value"))
        except ValueError:
            continue
    return None


def load_sabnzbd_state(
    exporter_url: str, timeout_seconds: float, exporter_instance: str | None
) -> dict | None:
    required_labels = None
    if exporter_instance is not None:
        required_labels = {"sabnzbd_instance": exporter_instance}

    metrics_text = fetch_url_text(exporter_url, timeout_seconds)
    paused_value = parse_prometheus_metric_value(
        SABNZBD_PAUSED_METRIC_RE, metrics_text, required_labels
    )
    queue_size_value = parse_prometheus_metric_value(
        SABNZBD_QUEUE_SIZE_METRIC_RE, metrics_text, required_labels
    )
    download_rate_value = parse_prometheus_metric_value(
        SABNZBD_QUEUE_DOWNLOAD_RATE_METRIC_RE, metrics_text, required_labels
    )

    if paused_value is None or queue_size_value is None:
        raise ExporterError(
            "SABnzbd exporter did not expose sabnzbd_paused and sabnzbd_queue_size"
        )

    paused = paused_value >= 0.5
    queue_size = max(0, int(round(queue_size_value)))
    download_rate_bytes_per_second = max(
        0,
        int(round(0.0 if download_rate_value is None else download_rate_value)),
    )
    return {
        "active": not paused and queue_size > 0,
        "download_rate_bytes_per_second": download_rate_bytes_per_second,
        "paused": paused,
        "queue_size": queue_size,
    }


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


def load_public_group_upload_limit_kbps(state_file: Path) -> int | None:
    if not state_file.exists():
        return None

    try:
        parsed = json.loads(state_file.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        LOG.warning("unable to read bandwidth state file %s: %s", state_file, exc)
        return None

    if not isinstance(parsed, dict):
        LOG.warning(
            "bandwidth state file %s does not contain a JSON object", state_file
        )
        return None

    public_group_upload_limit_kbps = parsed.get("public_group_upload_limit_kbps")
    if (
        not isinstance(public_group_upload_limit_kbps, int)
        or public_group_upload_limit_kbps <= 0
    ):
        return None

    return public_group_upload_limit_kbps


def load_transmission_upload_limit_kbps(state_file: Path) -> int | None:
    if not state_file.exists():
        return None

    try:
        parsed = json.loads(state_file.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        LOG.warning("unable to read bandwidth state file %s: %s", state_file, exc)
        return None

    if not isinstance(parsed, dict):
        LOG.warning(
            "bandwidth state file %s does not contain a JSON object", state_file
        )
        return None

    transmission_upload_limit_kbps = parsed.get("transmission_upload_limit_kbps")
    if (
        not isinstance(transmission_upload_limit_kbps, int)
        or transmission_upload_limit_kbps <= 0
    ):
        return None

    return transmission_upload_limit_kbps


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


def kilobytes_per_second_from_bytes_per_second(rate_bytes_per_second: int) -> int:
    if rate_bytes_per_second <= 0:
        return 0
    return math.ceil(rate_bytes_per_second / 1000.0)


def calculate_observed_public_group_upload_limit_kbps(
    *,
    transmission_upload_limit_kbps: int,
    preferred_upload_bytes_per_second: int,
    minimum_private_headroom_fraction: float,
    preferred_upload_headroom_fraction: float,
) -> int:
    preferred_upload_kbps = kilobytes_per_second_from_bytes_per_second(
        preferred_upload_bytes_per_second
    )
    reserved_private_kbps = max(
        1,
        math.ceil(transmission_upload_limit_kbps * minimum_private_headroom_fraction),
        math.ceil(preferred_upload_kbps * (1.0 + preferred_upload_headroom_fraction)),
    )
    return max(1, transmission_upload_limit_kbps - reserved_private_kbps)


def calculate_sabnzbd_public_group_upload_limit_kbps(
    transmission_upload_limit_kbps: int, sabnzbd_public_group_fraction: float
) -> int:
    return max(
        1, math.ceil(transmission_upload_limit_kbps * sabnzbd_public_group_fraction)
    )


def decide_public_group_upload_limit_kbps(
    *,
    now_monotonic: float,
    preferred_upload_active: bool,
    preferred_upload_bytes_per_second: int,
    transmission_upload_limit_kbps: int | None,
    conservative_public_group_upload_limit_kbps: int | None,
    current_public_group_upload_limit_kbps: int | None,
    pending_relaxed_public_group_upload_limit_kbps: int | None,
    pending_relaxed_since_monotonic: float | None,
    minimum_private_headroom_fraction: float,
    preferred_upload_headroom_fraction: float,
    relaxation_hold_seconds: float,
) -> tuple[int | None, int | None, int | None, float | None, int | None, str]:
    if not preferred_upload_active:
        return None, None, None, None, None, "preferred_inactive"

    if transmission_upload_limit_kbps is None:
        return (
            conservative_public_group_upload_limit_kbps,
            conservative_public_group_upload_limit_kbps,
            None,
            None,
            None,
            "missing_transmission_limit",
        )

    observed_public_group_upload_limit_kbps = (
        calculate_observed_public_group_upload_limit_kbps(
            transmission_upload_limit_kbps=transmission_upload_limit_kbps,
            preferred_upload_bytes_per_second=preferred_upload_bytes_per_second,
            minimum_private_headroom_fraction=minimum_private_headroom_fraction,
            preferred_upload_headroom_fraction=preferred_upload_headroom_fraction,
        )
    )
    bootstrap_public_group_upload_limit_kbps = (
        observed_public_group_upload_limit_kbps
        if conservative_public_group_upload_limit_kbps is None
        else min(
            conservative_public_group_upload_limit_kbps,
            observed_public_group_upload_limit_kbps,
        )
    )

    if current_public_group_upload_limit_kbps is None:
        if (
            observed_public_group_upload_limit_kbps
            > bootstrap_public_group_upload_limit_kbps
        ):
            return (
                bootstrap_public_group_upload_limit_kbps,
                bootstrap_public_group_upload_limit_kbps,
                observed_public_group_upload_limit_kbps,
                now_monotonic,
                observed_public_group_upload_limit_kbps,
                "holding_before_public_relaxation",
            )
        return (
            bootstrap_public_group_upload_limit_kbps,
            bootstrap_public_group_upload_limit_kbps,
            None,
            None,
            observed_public_group_upload_limit_kbps,
            "preferred_active_bootstrap",
        )

    if observed_public_group_upload_limit_kbps < current_public_group_upload_limit_kbps:
        return (
            observed_public_group_upload_limit_kbps,
            observed_public_group_upload_limit_kbps,
            None,
            None,
            observed_public_group_upload_limit_kbps,
            "tightening_for_preferred_upload",
        )

    if (
        observed_public_group_upload_limit_kbps
        == current_public_group_upload_limit_kbps
    ):
        return (
            current_public_group_upload_limit_kbps,
            current_public_group_upload_limit_kbps,
            None,
            None,
            observed_public_group_upload_limit_kbps,
            "preferred_upload_stable",
        )

    if (
        pending_relaxed_public_group_upload_limit_kbps is None
        or pending_relaxed_public_group_upload_limit_kbps
        != observed_public_group_upload_limit_kbps
        or pending_relaxed_since_monotonic is None
    ):
        return (
            current_public_group_upload_limit_kbps,
            current_public_group_upload_limit_kbps,
            observed_public_group_upload_limit_kbps,
            now_monotonic,
            observed_public_group_upload_limit_kbps,
            "holding_before_public_relaxation",
        )

    if now_monotonic - pending_relaxed_since_monotonic >= relaxation_hold_seconds:
        return (
            observed_public_group_upload_limit_kbps,
            observed_public_group_upload_limit_kbps,
            None,
            None,
            observed_public_group_upload_limit_kbps,
            "relaxed_for_sustained_low_preferred_upload",
        )

    return (
        current_public_group_upload_limit_kbps,
        current_public_group_upload_limit_kbps,
        pending_relaxed_public_group_upload_limit_kbps,
        pending_relaxed_since_monotonic,
        observed_public_group_upload_limit_kbps,
        "holding_before_public_relaxation",
    )


def render_metrics_text(
    *,
    torrent_counts: dict[str, int],
    torrent_activity_counts: dict[str, dict[str, int]],
    peer_counts: dict[str, dict[str, int]],
    download_bytes_per_second: dict[str, int],
    upload_bytes_per_second: dict[str, int],
    preferred_upload_active: bool,
    preferred_upload_bytes_per_second: int,
    public_group_upload_limit_kbps: int | None,
    observed_public_group_upload_limit_kbps: int | None,
) -> str:
    lines = [
        "# HELP host_observability_transmission_torrent_count Number of Transmission torrents by tracker-priority class.",
        "# TYPE host_observability_transmission_torrent_count gauge",
    ]
    for torrent_class in ("private", "public"):
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
            "# HELP host_observability_transmission_peer_count Number of Transmission peers by tracker-priority class and relationship.",
            "# TYPE host_observability_transmission_peer_count gauge",
        ]
    )
    for torrent_class in ("private", "public"):
        for state in ("connected", "getting_from_us", "sending_to_us"):
            lines.append(
                f'host_observability_transmission_peer_count{{class="{torrent_class}",state="{state}"}} {peer_counts[torrent_class][state]}'
            )

    lines.extend(
        [
            "# HELP host_observability_transmission_download_bytes_per_second Current aggregate download rate for Transmission torrents by tracker-priority class.",
            "# TYPE host_observability_transmission_download_bytes_per_second gauge",
        ]
    )
    for torrent_class in ("private", "public"):
        lines.append(
            f'host_observability_transmission_download_bytes_per_second{{class="{torrent_class}"}} {download_bytes_per_second[torrent_class]}'
        )

    lines.extend(
        [
            "# HELP host_observability_transmission_upload_bytes_per_second Current aggregate upload rate for Transmission torrents by tracker-priority class.",
            "# TYPE host_observability_transmission_upload_bytes_per_second gauge",
        ]
    )
    for torrent_class in ("private", "public"):
        lines.append(
            f'host_observability_transmission_upload_bytes_per_second{{class="{torrent_class}"}} {upload_bytes_per_second[torrent_class]}'
        )

    lines.extend(
        [
            "# HELP host_observability_transmission_preferred_upload_active Whether any preferred torrent is actively uploading to peers.",
            "# TYPE host_observability_transmission_preferred_upload_active gauge",
            f"host_observability_transmission_preferred_upload_active {1 if preferred_upload_active else 0}",
            "# HELP host_observability_transmission_preferred_upload_bytes_per_second Current aggregate upload rate for preferred torrents.",
            "# TYPE host_observability_transmission_preferred_upload_bytes_per_second gauge",
            f"host_observability_transmission_preferred_upload_bytes_per_second {preferred_upload_bytes_per_second}",
            "# HELP host_observability_transmission_public_group_upload_limit_bytes_per_second Effective upload cap for the managed public torrent group.",
            "# TYPE host_observability_transmission_public_group_upload_limit_bytes_per_second gauge",
            f"host_observability_transmission_public_group_upload_limit_bytes_per_second {0 if public_group_upload_limit_kbps is None else public_group_upload_limit_kbps * 1000}",
            "# HELP host_observability_transmission_observed_public_group_upload_limit_bytes_per_second Throughput-derived observed upload cap for the managed public torrent group before hysteresis is applied.",
            "# TYPE host_observability_transmission_observed_public_group_upload_limit_bytes_per_second gauge",
            f"host_observability_transmission_observed_public_group_upload_limit_bytes_per_second {0 if observed_public_group_upload_limit_kbps is None else observed_public_group_upload_limit_kbps * 1000}",
        ]
    )
    return "\n".join(lines) + "\n"


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
                "group",
                "peersConnected",
                "peersGettingFromUs",
                "peersSendingToUs",
                "leftUntilDone",
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


def rpc_configure_bandwidth_group(
    client: TransmissionRpcClient,
    group_name: str,
    upload_limit_kbps: int | None,
) -> None:
    arguments: dict[str, str | int | bool] = {
        "name": group_name,
        "honorsSessionLimits": True,
        "speed-limit-down-enabled": False,
    }

    if upload_limit_kbps is None:
        arguments["speed-limit-up-enabled"] = False
    else:
        arguments["speed-limit-up"] = upload_limit_kbps
        arguments["speed-limit-up-enabled"] = True

    client.call("group-set", arguments)


def run_iteration(
    client: TransmissionRpcClient,
    trackers_file: Path,
    public_group_name: str | None,
    public_group_upload_limit_kbps: int | None,
    bandwidth_state_file: Path | None,
    sabnzbd_exporter_url: str | None,
    sabnzbd_exporter_timeout_seconds: float,
    sabnzbd_exporter_instance: str | None,
    sabnzbd_public_group_fraction: float,
    metrics_file: Path | None,
    last_tracker_status: str | None,
    current_public_group_upload_limit_kbps: int | None,
    pending_relaxed_public_group_upload_limit_kbps: int | None,
    pending_relaxed_since_monotonic: float | None,
    last_preferred_activity_monotonic: float | None,
    minimum_private_headroom_fraction: float,
    preferred_upload_headroom_fraction: float,
    preferred_active_hold_seconds: float,
    public_group_relaxation_hold_seconds: float,
) -> tuple[str | None, int | None, int | None, float | None, float | None]:
    tracker_hosts = load_tracker_hosts(trackers_file)
    if tracker_hosts is None:
        status = f"missing:{trackers_file}"
        if status != last_tracker_status:
            LOG.warning(
                "tracker host file %s does not exist yet; skipping until it is created",
                trackers_file,
            )
        return (
            status,
            current_public_group_upload_limit_kbps,
            pending_relaxed_public_group_upload_limit_kbps,
            pending_relaxed_since_monotonic,
            last_preferred_activity_monotonic,
        )

    now_monotonic = time.monotonic()
    torrents = rpc_get_torrents(client)
    current_preferred_hashes: set[str] = set()
    preferred_upload_observed_active = False
    preferred_upload_active = False
    preferred_upload_bytes_per_second = 0
    torrent_counts = {
        "private": 0,
        "public": 0,
    }
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
    peer_counts = {
        "private": {
            "connected": 0,
            "getting_from_us": 0,
            "sending_to_us": 0,
        },
        "public": {
            "connected": 0,
            "getting_from_us": 0,
            "sending_to_us": 0,
        },
    }
    upload_bytes_per_second = {
        "private": 0,
        "public": 0,
    }
    download_bytes_per_second = {
        "private": 0,
        "public": 0,
    }
    to_prefer: list[str] = []
    to_make_public: list[str] = []

    for torrent in torrents:
        torrent_hash = torrent.get("hashString")
        if not isinstance(torrent_hash, str) or not torrent_hash:
            continue

        is_preferred = torrent_matches_tracker_hosts(torrent, tracker_hosts)
        torrent_class = "private" if is_preferred else "public"
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
        if isinstance(left_until_done, int):
            if left_until_done > 0:
                is_active_downloading = (
                    isinstance(peers_sending_to_us, int) and peers_sending_to_us > 0
                ) or (isinstance(rate_download, int) and rate_download > 0)
                torrent_activity_counts["downloading"][
                    "active" if is_active_downloading else "inactive"
                ] += 1
            else:
                is_active_seeding = (
                    isinstance(peers_getting_from_us, int) and peers_getting_from_us > 0
                ) or (isinstance(rate_upload, int) and rate_upload > 0)
                torrent_activity_counts["seeding"][
                    "active" if is_active_seeding else "inactive"
                ] += 1
        priority = torrent.get("bandwidthPriority")
        current_priority = priority if isinstance(priority, int) else TR_PRI_NORMAL
        group = torrent.get("group")
        current_group = group if isinstance(group, str) else ""

        if is_preferred:
            current_preferred_hashes.add(torrent_hash)
            if isinstance(rate_upload, int) and rate_upload > 0:
                preferred_upload_bytes_per_second += rate_upload
            if (
                isinstance(torrent.get("peersConnected"), int)
                and torrent["peersConnected"] > 0
            ) or (
                isinstance(peers_getting_from_us, int) and peers_getting_from_us > 0
            ) or (isinstance(rate_upload, int) and rate_upload > 0):
                preferred_upload_observed_active = True
            if current_priority != TR_PRI_HIGH or (
                public_group_name is not None and current_group != ""
            ):
                to_prefer.append(torrent_hash)
            continue

        if current_priority != TR_PRI_NORMAL or (
            public_group_name is not None and current_group != public_group_name
        ):
            to_make_public.append(torrent_hash)

    if preferred_upload_observed_active:
        preferred_upload_active = True
        last_preferred_activity_monotonic = now_monotonic
    elif (
        last_preferred_activity_monotonic is not None
        and now_monotonic - last_preferred_activity_monotonic
        < preferred_active_hold_seconds
    ):
        preferred_upload_active = True
    else:
        last_preferred_activity_monotonic = None

    conservative_public_group_upload_limit_kbps = public_group_upload_limit_kbps
    transmission_upload_limit_kbps = None
    if bandwidth_state_file is not None:
        dynamic_public_group_upload_limit_kbps = load_public_group_upload_limit_kbps(
            bandwidth_state_file
        )
        if dynamic_public_group_upload_limit_kbps is not None:
            conservative_public_group_upload_limit_kbps = (
                dynamic_public_group_upload_limit_kbps
            )
        transmission_upload_limit_kbps = load_transmission_upload_limit_kbps(
            bandwidth_state_file
        )

    sabnzbd_state = None
    if sabnzbd_exporter_url is not None:
        try:
            sabnzbd_state = load_sabnzbd_state(
                sabnzbd_exporter_url,
                sabnzbd_exporter_timeout_seconds,
                sabnzbd_exporter_instance,
            )
        except ExporterError as exc:
            LOG.warning("ignoring SABnzbd exporter state for this iteration: %s", exc)

    effective_public_group_upload_limit_kbps = None
    observed_public_group_upload_limit_kbps = None
    sabnzbd_public_group_upload_limit_kbps = None
    public_group_reason = "public_group_disabled"
    if public_group_name:
        (
            effective_public_group_upload_limit_kbps,
            current_public_group_upload_limit_kbps,
            pending_relaxed_public_group_upload_limit_kbps,
            pending_relaxed_since_monotonic,
            observed_public_group_upload_limit_kbps,
            public_group_reason,
        ) = decide_public_group_upload_limit_kbps(
            now_monotonic=now_monotonic,
            preferred_upload_active=preferred_upload_active,
            preferred_upload_bytes_per_second=preferred_upload_bytes_per_second,
            transmission_upload_limit_kbps=transmission_upload_limit_kbps,
            conservative_public_group_upload_limit_kbps=(
                conservative_public_group_upload_limit_kbps
            ),
            current_public_group_upload_limit_kbps=(
                current_public_group_upload_limit_kbps
            ),
            pending_relaxed_public_group_upload_limit_kbps=(
                pending_relaxed_public_group_upload_limit_kbps
            ),
            pending_relaxed_since_monotonic=pending_relaxed_since_monotonic,
            minimum_private_headroom_fraction=minimum_private_headroom_fraction,
            preferred_upload_headroom_fraction=preferred_upload_headroom_fraction,
            relaxation_hold_seconds=public_group_relaxation_hold_seconds,
        )
        if sabnzbd_state is not None and sabnzbd_state["active"]:
            if transmission_upload_limit_kbps is not None:
                sabnzbd_public_group_upload_limit_kbps = (
                    calculate_sabnzbd_public_group_upload_limit_kbps(
                        transmission_upload_limit_kbps,
                        sabnzbd_public_group_fraction,
                    )
                )
            elif conservative_public_group_upload_limit_kbps is not None:
                sabnzbd_public_group_upload_limit_kbps = max(
                    1,
                    min(
                        conservative_public_group_upload_limit_kbps,
                        calculate_sabnzbd_public_group_upload_limit_kbps(
                            conservative_public_group_upload_limit_kbps,
                            sabnzbd_public_group_fraction,
                        ),
                    ),
                )
            if sabnzbd_public_group_upload_limit_kbps is not None:
                if (
                    effective_public_group_upload_limit_kbps is None
                    or sabnzbd_public_group_upload_limit_kbps
                    < effective_public_group_upload_limit_kbps
                ):
                    effective_public_group_upload_limit_kbps = (
                        sabnzbd_public_group_upload_limit_kbps
                    )
                    public_group_reason = (
                        "sabnzbd_active"
                        if public_group_reason == "preferred_inactive"
                        else f"{public_group_reason}+sabnzbd_active"
                    )
                else:
                    public_group_reason = (
                        f"{public_group_reason}+sabnzbd_active_nonbinding"
                    )
        rpc_configure_bandwidth_group(
            client, public_group_name, effective_public_group_upload_limit_kbps
        )

    rpc_set_torrent_fields(
        client,
        sorted(to_prefer),
        {
            "bandwidthPriority": TR_PRI_HIGH,
            "group": "",
        },
    )
    public_fields = {
        "bandwidthPriority": TR_PRI_NORMAL,
    }
    if public_group_name is not None:
        public_fields["group"] = public_group_name
    rpc_set_torrent_fields(client, sorted(to_make_public), public_fields)

    if metrics_file is not None:
        write_text_atomic(
            metrics_file,
            render_metrics_text(
                torrent_counts=torrent_counts,
                torrent_activity_counts=torrent_activity_counts,
                peer_counts=peer_counts,
                download_bytes_per_second=download_bytes_per_second,
                upload_bytes_per_second=upload_bytes_per_second,
                preferred_upload_active=preferred_upload_active,
                preferred_upload_bytes_per_second=preferred_upload_bytes_per_second,
                public_group_upload_limit_kbps=effective_public_group_upload_limit_kbps,
                observed_public_group_upload_limit_kbps=(
                    observed_public_group_upload_limit_kbps
                ),
            ),
        )

    LOG.info(
        "iteration complete: tracker_hosts=%s preferred_torrents=%s preferred_upload_active=%s preferred_upload_observed_active=%s preferred_upload_bytes_per_second=%s sabnzbd_active=%s sabnzbd_paused=%s sabnzbd_queue_size=%s sabnzbd_download_rate_bytes_per_second=%s transmission_upload_limit_kbps=%s observed_public_group_upload_limit_kbps=%s sabnzbd_public_group_upload_limit_kbps=%s effective_public_group_upload_limit_kbps=%s public_group_reason=%s preferred_updates=%s public_updates=%s",
        len(tracker_hosts),
        len(current_preferred_hashes),
        preferred_upload_active,
        preferred_upload_observed_active,
        preferred_upload_bytes_per_second,
        None if sabnzbd_state is None else sabnzbd_state["active"],
        None if sabnzbd_state is None else sabnzbd_state["paused"],
        None if sabnzbd_state is None else sabnzbd_state["queue_size"],
        None
        if sabnzbd_state is None
        else sabnzbd_state["download_rate_bytes_per_second"],
        transmission_upload_limit_kbps,
        observed_public_group_upload_limit_kbps,
        sabnzbd_public_group_upload_limit_kbps,
        effective_public_group_upload_limit_kbps,
        public_group_reason,
        len(to_prefer),
        len(to_make_public),
    )
    return (
        f"loaded:{len(tracker_hosts)}",
        current_public_group_upload_limit_kbps,
        pending_relaxed_public_group_upload_limit_kbps,
        pending_relaxed_since_monotonic,
        last_preferred_activity_monotonic,
    )


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
        "--public-group-name",
        default="",
        help="Bandwidth group name to assign to non-priority torrents.",
    )
    parser.add_argument(
        "--public-group-upload-limit-kbps",
        type=int,
        default=None,
        help="Upload cap, in kB/s, for the managed public bandwidth group.",
    )
    parser.add_argument(
        "--bandwidth-state-file",
        default="",
        help="Optional adaptive upload policy state file used to derive current Transmission upload limits for public-group throttling.",
    )
    parser.add_argument(
        "--minimum-private-headroom-fraction",
        type=float,
        default=0.1,
        help="Minimum fraction of the current Transmission upload limit to keep reserved for preferred torrents while any preferred upload is active.",
    )
    parser.add_argument(
        "--preferred-upload-headroom-fraction",
        type=float,
        default=0.3,
        help="Extra headroom above the current preferred upload rate when deriving the public-group cap.",
    )
    parser.add_argument(
        "--preferred-active-hold-seconds",
        type=float,
        default=45.0,
        help="How long preferred torrents remain considered active after their last observed connected peer or upload activity.",
    )
    parser.add_argument(
        "--public-group-relaxation-hold-seconds",
        type=float,
        default=45.0,
        help="How long a more generous observed public-group cap must remain stable before it is applied.",
    )
    parser.add_argument(
        "--metrics-file",
        default="",
        help="Optional Prometheus textfile path for exported private/public torrent metrics.",
    )
    parser.add_argument(
        "--sabnzbd-exporter-url",
        default="",
        help="Optional SABnzbd exporter /metrics endpoint used to suppress public torrent uploads while SABnzbd has active queue work.",
    )
    parser.add_argument(
        "--sabnzbd-exporter-instance",
        default="",
        help="Optional sabnzbd_instance label value to match within the SABnzbd exporter metrics.",
    )
    parser.add_argument(
        "--sabnzbd-exporter-timeout-seconds",
        type=float,
        default=5.0,
        help="Per-request timeout when talking to the SABnzbd exporter.",
    )
    parser.add_argument(
        "--sabnzbd-public-group-fraction",
        type=float,
        default=0.1,
        help="Fraction of the current Transmission upload limit to leave available to public torrents while SABnzbd is active.",
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
    public_group_name = args.public_group_name.strip()
    if public_group_name == "":
        public_group_name = None
    bandwidth_state_file = Path(args.bandwidth_state_file.strip())
    if args.bandwidth_state_file.strip() == "":
        bandwidth_state_file = None
    sabnzbd_exporter_url = args.sabnzbd_exporter_url.strip()
    if sabnzbd_exporter_url == "":
        sabnzbd_exporter_url = None
    sabnzbd_exporter_instance = args.sabnzbd_exporter_instance.strip()
    if sabnzbd_exporter_instance == "":
        sabnzbd_exporter_instance = None
    metrics_file = Path(args.metrics_file.strip())
    if args.metrics_file.strip() == "":
        metrics_file = None
    public_group_upload_limit_kbps = args.public_group_upload_limit_kbps
    if (
        public_group_upload_limit_kbps is not None
        and public_group_upload_limit_kbps <= 0
    ):
        public_group_upload_limit_kbps = None
    last_tracker_status: str | None = None
    current_public_group_upload_limit_kbps: int | None = None
    pending_relaxed_public_group_upload_limit_kbps: int | None = None
    pending_relaxed_since_monotonic: float | None = None
    last_preferred_activity_monotonic: float | None = None

    while True:
        started_at = time.monotonic()
        try:
            (
                last_tracker_status,
                current_public_group_upload_limit_kbps,
                pending_relaxed_public_group_upload_limit_kbps,
                pending_relaxed_since_monotonic,
                last_preferred_activity_monotonic,
            ) = run_iteration(
                client=client,
                trackers_file=trackers_file,
                public_group_name=public_group_name,
                public_group_upload_limit_kbps=public_group_upload_limit_kbps,
                bandwidth_state_file=bandwidth_state_file,
                sabnzbd_exporter_url=sabnzbd_exporter_url,
                sabnzbd_exporter_timeout_seconds=(
                    args.sabnzbd_exporter_timeout_seconds
                ),
                sabnzbd_exporter_instance=sabnzbd_exporter_instance,
                sabnzbd_public_group_fraction=args.sabnzbd_public_group_fraction,
                metrics_file=metrics_file,
                last_tracker_status=last_tracker_status,
                current_public_group_upload_limit_kbps=(
                    current_public_group_upload_limit_kbps
                ),
                pending_relaxed_public_group_upload_limit_kbps=(
                    pending_relaxed_public_group_upload_limit_kbps
                ),
                pending_relaxed_since_monotonic=pending_relaxed_since_monotonic,
                last_preferred_activity_monotonic=last_preferred_activity_monotonic,
                minimum_private_headroom_fraction=(
                    args.minimum_private_headroom_fraction
                ),
                preferred_upload_headroom_fraction=(
                    args.preferred_upload_headroom_fraction
                ),
                preferred_active_hold_seconds=args.preferred_active_hold_seconds,
                public_group_relaxation_hold_seconds=(
                    args.public_group_relaxation_hold_seconds
                ),
            )
        except TransmissionRpcError as exc:
            LOG.warning("skipping iteration after Transmission RPC failure: %s", exc)
        except Exception:
            LOG.exception("skipping iteration after unexpected failure")

        sleep_for = max(0.0, args.interval_seconds - (time.monotonic() - started_at))
        time.sleep(sleep_for)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("", file=sys.stderr)
        raise SystemExit(0)
