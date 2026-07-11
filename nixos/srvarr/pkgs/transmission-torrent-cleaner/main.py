#!/usr/bin/env python3

import argparse
import logging
import sys
import time
from pathlib import Path

from transmission_common.transmission import (
    TransmissionRpcClient,
    TransmissionRpcError,
    read_tracker_hosts,
    torrent_matches_tracker_hosts,
)


LOG = logging.getLogger("transmission-torrent-cleaner")


def rpc_get_torrents(client: TransmissionRpcClient) -> list[dict]:
    result = client.call(
        "torrent_get",
        {
            "fields": [
                "id",
                "name",
                "hash_string",
                "added_date",
                "done_date",
                "left_until_done",
                "percent_done",
                "size_when_done",
                "tracker_stats",
                "upload_ratio",
            ]
        },
    )
    torrents = result.get("torrents", [])
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
    left_until_done = torrent.get("left_until_done")
    if isinstance(left_until_done, int) and left_until_done == 0:
        return True

    percent_done = torrent.get("percent_done")
    if isinstance(percent_done, (int, float)) and percent_done >= 0.999999:
        return True

    done_date = torrent.get("done_date")
    return isinstance(done_date, int) and done_date > 0


def torrent_completion_timestamp(torrent: dict) -> int | None:
    done_date = torrent.get("done_date")
    if isinstance(done_date, int) and done_date > 0:
        return done_date

    added_date = torrent.get("added_date")
    if isinstance(added_date, int) and added_date > 0:
        return added_date

    return None


def torrent_added_timestamp(torrent: dict) -> int | None:
    added_date = torrent.get("added_date")
    if isinstance(added_date, int) and added_date > 0:
        return added_date

    done_date = torrent.get("done_date")
    if isinstance(done_date, int) and done_date > 0:
        return done_date

    return None


def format_size_gib(size_bytes: int) -> str:
    return f"{size_bytes / (1024.0**3):.2f} GiB"


def format_age_days(age_days: float) -> str:
    return f"{age_days:.1f}d"


def run_once(args: argparse.Namespace) -> int:
    tracker_hosts = read_tracker_hosts(Path(args.trackers_file))
    client = TransmissionRpcClient(
        rpc_url=args.rpc_url,
        timeout_seconds=args.request_timeout_seconds,
    )
    now = time.time()
    minimum_age_seconds = args.minimum_age_days * 86400.0
    maximum_age_seconds = args.maximum_age_days * 86400.0
    minimum_ratio = args.minimum_ratio

    torrents = rpc_get_torrents(client)
    candidates: list[dict] = []

    for torrent in torrents:
        torrent_hash = torrent.get("hash_string")
        name = torrent.get("name")
        if not isinstance(torrent_hash, str) or not torrent_hash:
            continue
        if not isinstance(name, str) or not name:
            continue

        if torrent_matches_tracker_hosts(torrent, tracker_hosts):
            continue

        upload_ratio = torrent.get("upload_ratio")
        size_when_done = torrent.get("size_when_done")
        size_bytes = size_when_done if isinstance(size_when_done, int) else 0
        age_days: float | None = None
        reasons: list[str] = []

        added_timestamp = torrent_added_timestamp(torrent)
        if added_timestamp is not None:
            torrent_age_seconds = now - added_timestamp
            if torrent_age_seconds >= maximum_age_seconds:
                reasons.append("maximum-age")
                age_days = torrent_age_seconds / 86400.0

        if torrent_is_complete(torrent):
            completion_timestamp = torrent_completion_timestamp(torrent)
            if completion_timestamp is not None:
                completion_age_seconds = now - completion_timestamp
                if (
                    completion_age_seconds >= minimum_age_seconds
                    and isinstance(upload_ratio, (int, float))
                    and upload_ratio >= minimum_ratio
                ):
                    reasons.append("high-ratio")
                    if age_days is None:
                        age_days = completion_age_seconds / 86400.0

        if not reasons or age_days is None:
            continue

        candidates.append(
            {
                "hash": torrent_hash,
                "name": name,
                "ratio": (
                    float(upload_ratio)
                    if isinstance(upload_ratio, (int, float))
                    else None
                ),
                "age_days": age_days,
                "reasons": reasons,
                "size_bytes": size_bytes,
            }
        )

    candidates.sort(
        key=lambda candidate: (
            -(candidate["ratio"] if isinstance(candidate["ratio"], float) else 0.0),
            -candidate["age_days"],
            candidate["name"].lower(),
        )
    )

    mode = "delete" if args.delete else "dry-run"
    LOG.info(
        "scan complete: torrents=%s tracker_hosts=%s eligible=%s mode=%s minimum_age_days=%s minimum_ratio=%.2f maximum_age_days=%s",
        len(torrents),
        len(tracker_hosts),
        len(candidates),
        mode,
        args.minimum_age_days,
        minimum_ratio,
        args.maximum_age_days,
    )

    if not candidates:
        return 0

    total_size_bytes = 0
    for candidate in candidates:
        total_size_bytes += candidate["size_bytes"]
        ratio = candidate["ratio"]
        LOG.info(
            "%s candidate: reasons=%s name=%r hash=%s ratio=%s age=%s size=%s",
            "delete" if args.delete else "would delete",
            ",".join(candidate["reasons"]),
            candidate["name"],
            candidate["hash"],
            f"{ratio:.2f}" if isinstance(ratio, float) else "n/a",
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
        description="Delete or dry-run old high-ratio or over-age non-priority Transmission torrents.",
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
        "--maximum-age-days",
        type=float,
        default=365.0,
        help="Maximum torrent age in days before it becomes eligible regardless of status, completion, or ratio.",
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
