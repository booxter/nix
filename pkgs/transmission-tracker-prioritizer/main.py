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
TR_PRI_NORMAL = 0
TR_PRI_HIGH = 1


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


def render_metrics_text(
    *,
    torrent_counts: dict[str, int],
    peer_counts: dict[str, dict[str, int]],
    preferred_upload_active: bool,
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
            "# HELP host_observability_transmission_preferred_upload_active Whether any preferred torrent is actively uploading to peers.",
            "# TYPE host_observability_transmission_preferred_upload_active gauge",
            f"host_observability_transmission_preferred_upload_active {1 if preferred_upload_active else 0}",
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
    metrics_file: Path | None,
    last_tracker_status: str | None,
) -> str | None:
    tracker_hosts = load_tracker_hosts(trackers_file)
    if tracker_hosts is None:
        status = f"missing:{trackers_file}"
        if status != last_tracker_status:
            LOG.warning(
                "tracker host file %s does not exist yet; skipping until it is created",
                trackers_file,
            )
        return status

    torrents = rpc_get_torrents(client)
    current_preferred_hashes: set[str] = set()
    preferred_upload_active = False
    torrent_counts = {
        "private": 0,
        "public": 0,
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
        priority = torrent.get("bandwidthPriority")
        current_priority = priority if isinstance(priority, int) else TR_PRI_NORMAL
        group = torrent.get("group")
        current_group = group if isinstance(group, str) else ""

        if is_preferred:
            current_preferred_hashes.add(torrent_hash)
            peers_getting_from_us = torrent.get("peersGettingFromUs")
            rate_upload = torrent.get("rateUpload")
            if (
                isinstance(peers_getting_from_us, int) and peers_getting_from_us > 0
            ) or (isinstance(rate_upload, int) and rate_upload > 0):
                preferred_upload_active = True
            if current_priority != TR_PRI_HIGH or (
                public_group_name is not None and current_group != ""
            ):
                to_prefer.append(torrent_hash)
            continue

        if current_priority != TR_PRI_NORMAL or (
            public_group_name is not None and current_group != public_group_name
        ):
            to_make_public.append(torrent_hash)

    effective_public_group_upload_limit_kbps = public_group_upload_limit_kbps
    if bandwidth_state_file is not None:
        dynamic_public_group_upload_limit_kbps = load_public_group_upload_limit_kbps(
            bandwidth_state_file
        )
        if dynamic_public_group_upload_limit_kbps is not None:
            effective_public_group_upload_limit_kbps = (
                dynamic_public_group_upload_limit_kbps
            )

    if public_group_name:
        active_public_group_upload_limit_kbps = (
            effective_public_group_upload_limit_kbps
            if preferred_upload_active
            else None
        )
        rpc_configure_bandwidth_group(
            client, public_group_name, active_public_group_upload_limit_kbps
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
                peer_counts=peer_counts,
                preferred_upload_active=preferred_upload_active,
            ),
        )

    LOG.info(
        "iteration complete: tracker_hosts=%s preferred_torrents=%s preferred_upload_active=%s preferred_updates=%s public_updates=%s",
        len(tracker_hosts),
        len(current_preferred_hashes),
        preferred_upload_active,
        len(to_prefer),
        len(to_make_public),
    )
    return f"loaded:{len(tracker_hosts)}"


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
        help="Optional adaptive upload policy state file used to scale the public group cap.",
    )
    parser.add_argument(
        "--metrics-file",
        default="",
        help="Optional Prometheus textfile path for exported private/public torrent metrics.",
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

    while True:
        started_at = time.monotonic()
        try:
            last_tracker_status = run_iteration(
                client=client,
                trackers_file=trackers_file,
                public_group_name=public_group_name,
                public_group_upload_limit_kbps=public_group_upload_limit_kbps,
                bandwidth_state_file=bandwidth_state_file,
                metrics_file=metrics_file,
                last_tracker_status=last_tracker_status,
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
