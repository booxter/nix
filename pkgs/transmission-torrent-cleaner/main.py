#!/usr/bin/env python3

import argparse
import json
import logging
import socket
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path


LOG = logging.getLogger("transmission-torrent-cleaner")


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

            arguments_out = parsed.get("arguments", {})
            if not isinstance(arguments_out, dict):
                raise TransmissionRpcError(
                    "Transmission RPC returned invalid arguments payload"
                )
            return arguments_out

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


def load_tracker_hosts(trackers_file: Path) -> set[str]:
    lines = trackers_file.read_text().splitlines()
    hosts: set[str] = set()

    for raw_line in lines:
        line = raw_line.split("#", 1)[0].strip()
        if not line:
            continue
        host = normalize_tracker_host(line)
        if host:
            hosts.add(host)

    return hosts


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
                "addedDate",
                "doneDate",
                "leftUntilDone",
                "percentDone",
                "sizeWhenDone",
                "trackerStats",
                "uploadRatio",
            ]
        },
    )
    torrents = arguments.get("torrents", [])
    if not isinstance(torrents, list):
        raise TransmissionRpcError("Transmission RPC returned an invalid torrent list")
    return torrents


def rpc_remove_torrents(
    client: TransmissionRpcClient, torrent_hashes: list[str], delete_local_data: bool
) -> None:
    if not torrent_hashes:
        return

    client.call(
        "torrent_remove",
        {
            "ids": torrent_hashes,
            "delete_local_data": delete_local_data,
        },
    )


def torrent_is_complete(torrent: dict) -> bool:
    left_until_done = torrent.get("leftUntilDone")
    if isinstance(left_until_done, int) and left_until_done == 0:
        return True

    percent_done = torrent.get("percentDone")
    if isinstance(percent_done, (int, float)) and percent_done >= 0.999999:
        return True

    done_date = torrent.get("doneDate")
    return isinstance(done_date, int) and done_date > 0


def torrent_completion_timestamp(torrent: dict) -> int | None:
    done_date = torrent.get("doneDate")
    if isinstance(done_date, int) and done_date > 0:
        return done_date

    added_date = torrent.get("addedDate")
    if isinstance(added_date, int) and added_date > 0:
        return added_date

    return None


def format_size_gib(size_bytes: int) -> str:
    return f"{size_bytes / (1024.0**3):.2f} GiB"


def format_age_days(age_days: float) -> str:
    return f"{age_days:.1f}d"


def run_once(args: argparse.Namespace) -> int:
    tracker_hosts = load_tracker_hosts(Path(args.trackers_file))
    client = TransmissionRpcClient(
        rpc_url=args.rpc_url,
        timeout_seconds=args.request_timeout_seconds,
    )
    now = time.time()
    minimum_age_seconds = args.minimum_age_days * 86400.0
    minimum_ratio = args.minimum_ratio

    torrents = rpc_get_torrents(client)
    candidates: list[dict] = []

    for torrent in torrents:
        torrent_hash = torrent.get("hashString")
        name = torrent.get("name")
        if not isinstance(torrent_hash, str) or not torrent_hash:
            continue
        if not isinstance(name, str) or not name:
            continue

        if torrent_matches_tracker_hosts(torrent, tracker_hosts):
            continue

        if not torrent_is_complete(torrent):
            continue

        completion_timestamp = torrent_completion_timestamp(torrent)
        if completion_timestamp is None:
            continue

        age_seconds = now - completion_timestamp
        if age_seconds < minimum_age_seconds:
            continue

        upload_ratio = torrent.get("uploadRatio")
        if not isinstance(upload_ratio, (int, float)) or upload_ratio < minimum_ratio:
            continue

        size_when_done = torrent.get("sizeWhenDone")
        size_bytes = size_when_done if isinstance(size_when_done, int) else 0
        age_days = age_seconds / 86400.0
        candidates.append(
            {
                "hash": torrent_hash,
                "name": name,
                "ratio": float(upload_ratio),
                "age_days": age_days,
                "size_bytes": size_bytes,
            }
        )

    candidates.sort(
        key=lambda candidate: (
            -candidate["ratio"],
            -candidate["age_days"],
            candidate["name"].lower(),
        )
    )

    mode = "delete" if args.delete else "dry-run"
    LOG.info(
        "scan complete: torrents=%s tracker_hosts=%s eligible=%s mode=%s minimum_age_days=%s minimum_ratio=%.2f",
        len(torrents),
        len(tracker_hosts),
        len(candidates),
        mode,
        args.minimum_age_days,
        minimum_ratio,
    )

    if not candidates:
        return 0

    total_size_bytes = 0
    for candidate in candidates:
        total_size_bytes += candidate["size_bytes"]
        LOG.info(
            "%s candidate: name=%r hash=%s ratio=%.2f age=%s size=%s",
            "delete" if args.delete else "would delete",
            candidate["name"],
            candidate["hash"],
            candidate["ratio"],
            format_age_days(candidate["age_days"]),
            format_size_gib(candidate["size_bytes"]),
        )

    LOG.info(
        "%s summary: count=%s total_size=%s",
        "delete" if args.delete else "dry-run",
        len(candidates),
        format_size_gib(total_size_bytes),
    )

    if args.delete:
        rpc_remove_torrents(
            client,
            [candidate["hash"] for candidate in candidates],
            delete_local_data=True,
        )
        LOG.warning(
            "deleted %s torrent(s) with local data after matching cleanup policy",
            len(candidates),
        )

    return 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Delete or dry-run old high-ratio non-priority Transmission torrents.",
    )
    parser.add_argument(
        "--rpc-url",
        default="http://127.0.0.1:9091/transmission/rpc",
        help="Transmission RPC URL.",
    )
    parser.add_argument(
        "--trackers-file",
        required=True,
        help="Path to the prioritized tracker host file used to exempt torrents from cleanup.",
    )
    parser.add_argument(
        "--minimum-age-days",
        type=float,
        default=30.0,
        help="Minimum completion age in days before a torrent becomes eligible.",
    )
    parser.add_argument(
        "--minimum-ratio",
        type=float,
        default=3.0,
        help="Minimum upload ratio before a torrent becomes eligible.",
    )
    parser.add_argument(
        "--request-timeout-seconds",
        type=float,
        default=20.0,
        help="Per-request timeout when talking to Transmission.",
    )
    parser.add_argument(
        "--delete",
        action="store_true",
        help="Actually remove matching torrents and their local data. Default is dry-run logging only.",
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

    try:
        return run_once(args)
    except FileNotFoundError as exc:
        LOG.error("required file is missing: %s", exc)
        return 1
    except OSError as exc:
        LOG.error("failed to read tracker host file: %s", exc)
        return 1
    except TransmissionRpcError as exc:
        LOG.error("cleanup run failed after Transmission RPC error: %s", exc)
        return 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("", file=sys.stderr)
        raise SystemExit(130)
