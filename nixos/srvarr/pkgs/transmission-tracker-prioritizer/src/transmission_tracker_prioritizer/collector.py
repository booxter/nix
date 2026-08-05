import argparse
import logging
import sys
from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol

from transmission_common.transmission import TransmissionRpcError

from .core import (
    Clock,
    DaemonSettings,
    SystemClock,
    TorrentClient,
    add_common_arguments,
    build_client,
    collect_iteration_state,
    settings_from_args,
    write_health_metrics,
    write_iteration_metrics,
)


LOG = logging.getLogger("transmission-collector")


@dataclass(frozen=True)
class CollectorSettings:
    daemon: DaemonSettings
    metrics_file: Path


class Runner(Protocol):
    def __call__(
        self,
        settings: CollectorSettings,
        client: TorrentClient,
        clock: Clock,
        *,
        iterations: int | None = None,
    ) -> None: ...


def run(
    settings: CollectorSettings,
    client: TorrentClient,
    clock: Clock,
    *,
    iterations: int | None = None,
) -> None:
    last_tracker_status: str | None = None
    last_success: float | None = None
    completed = 0
    while iterations is None or completed < iterations:
        started_at = clock.monotonic()
        timestamp = clock.time()
        try:
            last_tracker_status, state = collect_iteration_state(
                client,
                settings.daemon.trackers_file,
                last_tracker_status,
                settings.daemon.policy,
            )
            if state is None:
                write_health_metrics(
                    settings.metrics_file,
                    exporter_ok=False,
                    last_run_timestamp_seconds=timestamp,
                    last_success_timestamp_seconds=last_success,
                )
            else:
                write_iteration_metrics(settings.metrics_file, state, timestamp)
                last_success = timestamp
                LOG.info(
                    "iteration complete: tracker_hosts=%s preferred_torrents=%s "
                    "preferred_bootstrap_active=%s preferred_upload_active=%s "
                    "preferred_upload_bytes_per_second=%s observed_high_priority_changes=%s "
                    "observed_normal_priority_changes=%s observed_low_priority_changes=%s "
                    "observed_stop_actions=%s",
                    state.tracker_hosts_count,
                    state.preferred_torrent_count,
                    state.preferred_bootstrap_active,
                    state.preferred_upload_active,
                    state.preferred_upload_bytes_per_second,
                    len(state.high_priority_hashes),
                    len(state.normal_priority_hashes),
                    len(state.low_priority_hashes),
                    len(state.stop_hashes),
                )
        except TransmissionRpcError as exc:
            LOG.warning("skipping iteration after Transmission RPC failure: %s", exc)
            write_health_metrics(
                settings.metrics_file,
                exporter_ok=False,
                last_run_timestamp_seconds=timestamp,
                last_success_timestamp_seconds=last_success,
            )
        except Exception:
            LOG.exception("skipping iteration after unexpected failure")
            write_health_metrics(
                settings.metrics_file,
                exporter_ok=False,
                last_run_timestamp_seconds=timestamp,
                last_success_timestamp_seconds=last_success,
            )
        completed += 1
        if iterations is None or completed < iterations:
            clock.sleep(
                max(
                    0.0,
                    settings.daemon.interval_seconds - (clock.monotonic() - started_at),
                )
            )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="transmission-collector",
        description="Continuously collect Transmission torrent metrics by tracker.",
    )
    add_common_arguments(parser)
    parser.add_argument("--metrics-file", required=True, type=Path)
    return parser


def main(argv: Sequence[str] | None = None, runner: Runner | None = None) -> int:
    args = build_parser().parse_args(argv)
    logging.basicConfig(
        level=getattr(logging, args.log_level),
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    settings = CollectorSettings(settings_from_args(args), args.metrics_file)
    try:
        (runner or run)(settings, build_client(settings.daemon), SystemClock())
    except KeyboardInterrupt:
        print("", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
