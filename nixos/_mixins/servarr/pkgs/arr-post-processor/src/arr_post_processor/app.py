from __future__ import annotations

import argparse
import logging
import sys
import time
from pathlib import Path
from typing import Protocol

from .archive import NativeArchiveBackend
from .config import read_api_key
from .lidarr import LidarrClient
from .media import UnflacRunner
from .media_join import CommandJoinBackend
from .radarr import RadarrClient
from .radarr_service import RadarrJoinService
from .service import CueSplitterService
from .state import StateStore


LOG = logging.getLogger("arr-post-processor")


class RuntimeService(Protocol):
    def iteration(self) -> None: ...

    def write_metrics(self, ok: bool) -> None: ...


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run a queue-aware post-processor for a Servarr application."
    )
    parser.add_argument(
        "--processor", required=True, choices=["lidarr-cue-split", "radarr-media-join"]
    )
    parser.add_argument("--arr-url", required=True)
    parser.add_argument("--arr-config", required=True)
    parser.add_argument("--allowed-root", action="append", required=True)
    parser.add_argument("--work-root", required=True)
    parser.add_argument("--state-file", required=True)
    parser.add_argument("--metrics-file", required=True)
    parser.add_argument("--interval-seconds", type=float, default=30.0)
    parser.add_argument("--settle-seconds", type=float, default=30.0)
    parser.add_argument("--request-timeout-seconds", type=float, default=20.0)
    parser.add_argument("--command-timeout-seconds", type=float, default=900.0)
    parser.add_argument("--once", action="store_true")
    parser.add_argument(
        "--log-level", default="INFO", choices=["DEBUG", "INFO", "WARNING", "ERROR"]
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    logging.basicConfig(
        level=getattr(logging, args.log_level),
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    store = StateStore(Path(args.state_file))

    service: RuntimeService
    if args.processor == "lidarr-cue-split":

        def lidarr_client_factory() -> LidarrClient:
            return LidarrClient(
                args.arr_url,
                read_api_key(Path(args.arr_config)),
                args.request_timeout_seconds,
            )

        service = CueSplitterService(
            client_factory=lidarr_client_factory,
            runner=UnflacRunner(),
            archive_backend=NativeArchiveBackend(),
            store=store,
            allowed_roots=[Path(root) for root in args.allowed_root],
            work_root=Path(args.work_root),
            metrics_file=Path(args.metrics_file),
            settle_seconds=args.settle_seconds,
            command_timeout_seconds=args.command_timeout_seconds,
        )
    else:

        def radarr_client_factory() -> RadarrClient:
            return RadarrClient(
                args.arr_url,
                read_api_key(Path(args.arr_config)),
                args.request_timeout_seconds,
            )

        service = RadarrJoinService(
            client_factory=radarr_client_factory,
            backend=CommandJoinBackend(timeout_seconds=args.command_timeout_seconds),
            store=store,
            allowed_roots=[Path(root) for root in args.allowed_root],
            work_root=Path(args.work_root),
            metrics_file=Path(args.metrics_file),
            settle_seconds=args.settle_seconds,
            command_timeout_seconds=args.command_timeout_seconds,
        )
    while True:
        started = time.monotonic()
        ok = True
        try:
            service.iteration()
        except Exception:
            ok = False
            LOG.exception("service iteration failed")
        service.write_metrics(ok)
        if args.once:
            return 0 if ok else 1
        time.sleep(max(0.0, args.interval_seconds - (time.monotonic() - started)))


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("", file=sys.stderr)
        raise SystemExit(0)
