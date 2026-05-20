#!/usr/bin/env python3

import argparse
import logging
import sys
import time
from pathlib import Path

from main import (
    DEFAULT_NON_PREFERRED_LOW_PRIORITY_RATIO_THRESHOLD,
    TransmissionRpcClient,
    TransmissionRpcError,
    apply_priority_updates,
    collect_iteration_state,
)


LOG = logging.getLogger("transmission-tracker-prioritizer")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Continuously enforce Transmission bandwidth priority for torrents based on selected trackers.",
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
        help="Upload ratio threshold at or above which non-preferred torrents are demoted to low priority.",
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
    last_tracker_status: str | None = None

    while True:
        started_at = time.monotonic()
        try:
            last_tracker_status, state = collect_iteration_state(
                client=client,
                trackers_file=trackers_file,
                last_tracker_status=last_tracker_status,
                non_preferred_low_priority_ratio_threshold=args.non_preferred_low_priority_ratio,
            )
            if state is not None:
                apply_priority_updates(client, state)
                LOG.info(
                    "iteration complete: tracker_hosts=%s preferred_torrents=%s preferred_bootstrap_active=%s preferred_upload_active=%s preferred_upload_bytes_per_second=%s applied_high_priority_changes=%s applied_normal_priority_changes=%s applied_low_priority_changes=%s",
                    state.tracker_hosts_count,
                    state.preferred_torrent_count,
                    state.preferred_bootstrap_active,
                    state.preferred_upload_active,
                    state.preferred_upload_bytes_per_second,
                    len(state.high_priority_hashes),
                    len(state.normal_priority_hashes),
                    len(state.low_priority_hashes),
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
