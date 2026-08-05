import argparse
import logging
import sys
from collections.abc import Sequence
from typing import Protocol

from transmission_common.transmission import TransmissionRpcError

from .core import (
    Clock,
    DaemonSettings,
    SystemClock,
    TorrentClient,
    add_common_arguments,
    apply_priority_updates,
    build_client,
    collect_iteration_state,
    settings_from_args,
)


LOG = logging.getLogger("transmission-prioritizer")


class Runner(Protocol):
    def __call__(
        self,
        settings: DaemonSettings,
        client: TorrentClient,
        clock: Clock,
        *,
        iterations: int | None = None,
    ) -> None: ...


def run(
    settings: DaemonSettings,
    client: TorrentClient,
    clock: Clock,
    *,
    iterations: int | None = None,
) -> None:
    last_tracker_status: str | None = None
    completed = 0
    while iterations is None or completed < iterations:
        started_at = clock.monotonic()
        try:
            last_tracker_status, state = collect_iteration_state(
                client, settings.trackers_file, last_tracker_status, settings.policy
            )
            if state is not None:
                apply_priority_updates(client, state)
                LOG.info(
                    "iteration complete: tracker_hosts=%s preferred_torrents=%s "
                    "preferred_bootstrap_active=%s preferred_upload_active=%s "
                    "preferred_upload_bytes_per_second=%s applied_high_priority_changes=%s "
                    "applied_normal_priority_changes=%s applied_low_priority_changes=%s "
                    "applied_stop_actions=%s",
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
        except Exception:
            LOG.exception("skipping iteration after unexpected failure")
        completed += 1
        if iterations is None or completed < iterations:
            clock.sleep(max(0.0, settings.interval_seconds - (clock.monotonic() - started_at)))


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="transmission-prioritizer",
        description="Continuously enforce Transmission torrent priority by tracker.",
    )
    add_common_arguments(parser)
    return parser


def main(argv: Sequence[str] | None = None, runner: Runner | None = None) -> int:
    args = build_parser().parse_args(argv)
    logging.basicConfig(
        level=getattr(logging, args.log_level),
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    settings = settings_from_args(args)
    try:
        (runner or run)(settings, build_client(settings), SystemClock())
    except KeyboardInterrupt:
        print("", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
