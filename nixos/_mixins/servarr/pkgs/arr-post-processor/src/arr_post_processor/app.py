from __future__ import annotations

import argparse
import logging
import sys
import time
from pathlib import Path
from typing import Protocol

from hermes_runs.client import HermesClient

from .archive import NativeArchiveBackend
from .config import read_api_key, read_environment_value
from .lidarr import LidarrClient
from .lidarr_service import LidarrPostProcessorService
from .media import UnflacRunner
from .radarr import RadarrClient
from .radarr_agent_service import RadarrAgentService
from .radarr_probe import CommandVideoVerifier
from .radarr_source import SourceRoot
from .radarr_state import RepairStateStore
from .state import StateStore

LOG = logging.getLogger("arr-post-processor")


class RuntimeService(Protocol):
    def iteration(self) -> None: ...

    def write_metrics(self, ok: bool) -> None: ...


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run a queue-aware post-processor for a Servarr application."
    )
    parser.add_argument("--processor", required=True, choices=["lidarr", "radarr"])
    parser.add_argument("--arr-url", required=True)
    parser.add_argument("--arr-config", required=True)
    parser.add_argument("--allowed-root", action="append", default=[])
    parser.add_argument("--work-root")
    parser.add_argument("--source-root", action="append", default=[])
    parser.add_argument("--output-root")
    parser.add_argument("--audit-root")
    parser.add_argument("--hermes-url")
    parser.add_argument("--hermes-api-key-file")
    parser.add_argument("--state-file", required=True)
    parser.add_argument("--metrics-file", required=True)
    parser.add_argument("--interval-seconds", type=float, default=30.0)
    parser.add_argument("--settle-seconds", type=float, default=30.0)
    parser.add_argument("--request-timeout-seconds", type=float, default=20.0)
    parser.add_argument("--command-timeout-seconds", type=float, default=900.0)
    parser.add_argument("--agent-timeout-seconds", type=float, default=14400.0)
    parser.add_argument("--once", action="store_true")
    parser.add_argument(
        "--log-level", default="INFO", choices=["DEBUG", "INFO", "WARNING", "ERROR"]
    )
    args = parser.parse_args()
    if args.processor == "lidarr":
        if not args.allowed_root or args.work_root is None:
            parser.error("Lidarr requires --allowed-root and --work-root")
    else:
        required = {
            "--source-root": args.source_root,
            "--output-root": args.output_root,
            "--audit-root": args.audit_root,
            "--hermes-url": args.hermes_url,
            "--hermes-api-key-file": args.hermes_api_key_file,
        }
        missing = [name for name, value in required.items() if not value]
        if missing:
            parser.error(f"Radarr requires {', '.join(missing)}")
    return args


def parse_source_roots(values: list[str]) -> tuple[SourceRoot, ...]:
    roots: list[SourceRoot] = []
    names: set[str] = set()
    for value in values:
        name, separator, path = value.partition("=")
        if not separator or not name or not path or not name.replace("-", "").isalnum():
            raise ValueError(f"invalid source root {value!r}; expected name=/absolute/path")
        if name in names:
            raise ValueError(f"duplicate source root name: {name}")
        root = Path(path)
        if not root.is_absolute():
            raise ValueError(f"source root must be absolute: {path}")
        names.add(name)
        roots.append(SourceRoot(name=name, host_path=root))
    return tuple(roots)


def main() -> int:
    args = parse_args()
    logging.basicConfig(
        level=getattr(logging, args.log_level),
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    service: RuntimeService
    if args.processor == "lidarr":
        store = StateStore(Path(args.state_file))

        def lidarr_client_factory() -> LidarrClient:
            return LidarrClient(
                args.arr_url,
                read_api_key(Path(args.arr_config)),
                args.request_timeout_seconds,
            )

        service = LidarrPostProcessorService(
            client_factory=lidarr_client_factory,
            runner=UnflacRunner(),
            archive_backend=NativeArchiveBackend(
                timeout_seconds=args.command_timeout_seconds,
            ),
            store=store,
            allowed_roots=[Path(root) for root in args.allowed_root],
            work_root=Path(args.work_root),
            metrics_file=Path(args.metrics_file),
            settle_seconds=args.settle_seconds,
            command_timeout_seconds=args.command_timeout_seconds,
        )
    else:
        repair_store = RepairStateStore(Path(args.state_file))

        def radarr_client_factory() -> RadarrClient:
            return RadarrClient(
                args.arr_url,
                read_api_key(Path(args.arr_config)),
                args.request_timeout_seconds,
            )

        service = RadarrAgentService(
            client_factory=radarr_client_factory,
            hermes=HermesClient(
                args.hermes_url,
                read_environment_value(Path(args.hermes_api_key_file), "API_SERVER_KEY"),
                timeout_seconds=args.request_timeout_seconds,
            ),
            store=repair_store,
            source_roots=parse_source_roots(args.source_root),
            output_root=Path(args.output_root),
            audit_root=Path(args.audit_root),
            metrics_file=Path(args.metrics_file),
            verifier=CommandVideoVerifier(timeout_seconds=args.command_timeout_seconds),
            settle_seconds=args.settle_seconds,
            agent_timeout_seconds=args.agent_timeout_seconds,
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
