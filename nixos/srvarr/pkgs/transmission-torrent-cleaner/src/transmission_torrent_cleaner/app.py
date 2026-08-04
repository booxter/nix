import argparse
import logging
import sys
import time
from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol, cast

from pydantic import BaseModel, ConfigDict, Field, ValidationError
from transmission_common.transmission import (
    TransmissionRpcClient,
    TransmissionRpcError,
    normalize_tracker_host,
    read_tracker_hosts,
)


LOG = logging.getLogger("transmission-torrent-cleaner")
DAY_SECONDS = 86_400.0
TORRENT_FIELDS = [
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


class Tracker(BaseModel):
    model_config = ConfigDict(extra="allow", frozen=True, strict=True)

    host: str | None = None
    announce: str | None = None


class Torrent(BaseModel):
    model_config = ConfigDict(extra="allow", frozen=True, strict=True)

    hash_string: str = ""
    name: str = ""
    added_date: int = 0
    done_date: int = 0
    left_until_done: int | None = None
    percent_done: int | float | None = None
    size_when_done: int = Field(default=0, ge=0)
    tracker_stats: list[Tracker] = Field(default_factory=list)
    upload_ratio: int | float | None = None


class TorrentList(BaseModel):
    model_config = ConfigDict(extra="allow", frozen=True, strict=True)

    torrents: list[Torrent] = Field(default_factory=list)


@dataclass(frozen=True)
class Policy:
    minimum_age_days: float
    minimum_ratio: float
    maximum_age_days: float


@dataclass(frozen=True)
class Settings:
    rpc_url: str
    trackers_file: Path
    request_timeout_seconds: float
    policy: Policy
    delete: bool


@dataclass(frozen=True)
class Candidate:
    hash: str
    name: str
    ratio: float | None
    age_days: float
    reasons: tuple[str, ...]
    size_bytes: int


class RpcTransport(Protocol):
    def call(self, method: str, params: dict[str, object] | None = None) -> dict[str, object]: ...


class TorrentClient(Protocol):
    def list_torrents(self) -> list[Torrent]: ...

    def remove_torrents(
        self, torrent_hashes: Sequence[str], *, delete_local_data: bool
    ) -> None: ...


class Clock(Protocol):
    def now(self) -> float: ...


@dataclass(frozen=True)
class SystemClock:
    def now(self) -> float:
        return time.time()


@dataclass(frozen=True)
class TransmissionClient:
    rpc: RpcTransport

    def list_torrents(self) -> list[Torrent]:
        response: object = self.rpc.call("torrent_get", {"fields": TORRENT_FIELDS})
        try:
            return TorrentList.model_validate(response).torrents
        except ValidationError as exc:
            raise TransmissionRpcError(
                f"Transmission RPC returned an invalid torrent list: {exc}"
            ) from exc

    def remove_torrents(self, torrent_hashes: Sequence[str], *, delete_local_data: bool) -> None:
        if not torrent_hashes:
            return
        self.rpc.call(
            "torrent_remove",
            {
                "ids": list(torrent_hashes),
                "delete_local_data": delete_local_data,
            },
        )


def torrent_is_complete(torrent: Torrent) -> bool:
    return (
        torrent.left_until_done == 0
        or (torrent.percent_done is not None and torrent.percent_done >= 0.999999)
        or torrent.done_date > 0
    )


def torrent_completion_timestamp(torrent: Torrent) -> int | None:
    if torrent.done_date > 0:
        return torrent.done_date
    if torrent.added_date > 0:
        return torrent.added_date
    return None


def torrent_added_timestamp(torrent: Torrent) -> int | None:
    if torrent.added_date > 0:
        return torrent.added_date
    if torrent.done_date > 0:
        return torrent.done_date
    return None


def torrent_matches_tracker_hosts(torrent: Torrent, tracker_hosts: set[str]) -> bool:
    for tracker in torrent.tracker_stats:
        for raw_host in (tracker.host, tracker.announce):
            if raw_host is None:
                continue
            host = cast(str, normalize_tracker_host(raw_host))
            if host and host in tracker_hosts:
                return True
    return False


def select_candidates(
    torrents: Sequence[Torrent], tracker_hosts: set[str], policy: Policy, now: float
) -> list[Candidate]:
    minimum_age_seconds = policy.minimum_age_days * DAY_SECONDS
    maximum_age_seconds = policy.maximum_age_days * DAY_SECONDS
    candidates: list[Candidate] = []

    for torrent in torrents:
        if not torrent.hash_string or not torrent.name:
            continue
        if torrent_matches_tracker_hosts(torrent, tracker_hosts):
            continue

        age_days: float | None = None
        reasons: list[str] = []
        added_timestamp = torrent_added_timestamp(torrent)
        if added_timestamp is not None:
            torrent_age_seconds = now - added_timestamp
            if torrent_age_seconds >= maximum_age_seconds:
                reasons.append("maximum-age")
                age_days = torrent_age_seconds / DAY_SECONDS

        if torrent_is_complete(torrent):
            completion_timestamp = torrent_completion_timestamp(torrent)
            if completion_timestamp is not None:
                completion_age_seconds = now - completion_timestamp
                if (
                    completion_age_seconds >= minimum_age_seconds
                    and torrent.upload_ratio is not None
                    and torrent.upload_ratio >= policy.minimum_ratio
                ):
                    reasons.append("high-ratio")
                    if age_days is None:
                        age_days = completion_age_seconds / DAY_SECONDS

        if not reasons or age_days is None:
            continue
        candidates.append(
            Candidate(
                hash=torrent.hash_string,
                name=torrent.name,
                ratio=None if torrent.upload_ratio is None else float(torrent.upload_ratio),
                age_days=age_days,
                reasons=tuple(reasons),
                size_bytes=torrent.size_when_done,
            )
        )

    return sorted(
        candidates,
        key=lambda candidate: (
            -(candidate.ratio if candidate.ratio is not None else 0.0),
            -candidate.age_days,
            candidate.name.lower(),
        ),
    )


def format_size_gib(size_bytes: int) -> str:
    return f"{size_bytes / (1024.0**3):.2f} GiB"


def format_age_days(age_days: float) -> str:
    return f"{age_days:.1f}d"


def load_tracker_hosts(path: Path) -> set[str]:
    return cast(set[str], read_tracker_hosts(path))


def run_cleanup(settings: Settings, client: TorrentClient, clock: Clock) -> int:
    tracker_hosts = load_tracker_hosts(settings.trackers_file)
    torrents = client.list_torrents()
    candidates = select_candidates(torrents, tracker_hosts, settings.policy, clock.now())
    mode = "delete" if settings.delete else "dry-run"

    LOG.info(
        "scan complete: torrents=%s tracker_hosts=%s eligible=%s mode=%s "
        "minimum_age_days=%s minimum_ratio=%.2f maximum_age_days=%s",
        len(torrents),
        len(tracker_hosts),
        len(candidates),
        mode,
        settings.policy.minimum_age_days,
        settings.policy.minimum_ratio,
        settings.policy.maximum_age_days,
    )
    if not candidates:
        return 0

    for candidate in candidates:
        LOG.info(
            "%s candidate: reasons=%s name=%r hash=%s ratio=%s age=%s size=%s",
            "delete" if settings.delete else "would delete",
            ",".join(candidate.reasons),
            candidate.name,
            candidate.hash,
            f"{candidate.ratio:.2f}" if candidate.ratio is not None else "n/a",
            format_age_days(candidate.age_days),
            format_size_gib(candidate.size_bytes),
        )

    LOG.info(
        "%s summary: count=%s total_size=%s",
        "delete" if settings.delete else "dry-run",
        len(candidates),
        format_size_gib(sum(candidate.size_bytes for candidate in candidates)),
    )
    if settings.delete:
        client.remove_torrents([candidate.hash for candidate in candidates], delete_local_data=True)
        LOG.warning(
            "deleted %s torrent(s) with local data after matching cleanup policy",
            len(candidates),
        )
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="transmission-torrent-cleaner",
        description=(
            "Delete or dry-run old high-ratio or over-age non-priority Transmission torrents."
        ),
    )
    parser.add_argument("--rpc-url", default="http://127.0.0.1:9091/transmission/rpc")
    parser.add_argument("--trackers-file", required=True, type=Path)
    parser.add_argument("--minimum-age-days", type=float, default=30.0)
    parser.add_argument("--minimum-ratio", type=float, default=3.0)
    parser.add_argument("--maximum-age-days", type=float, default=365.0)
    parser.add_argument("--request-timeout-seconds", type=float, default=20.0)
    parser.add_argument("--delete", action="store_true")
    parser.add_argument(
        "--log-level",
        default="INFO",
        choices=["DEBUG", "INFO", "WARNING", "ERROR"],
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    logging.basicConfig(
        level=getattr(logging, args.log_level),
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    settings = Settings(
        rpc_url=args.rpc_url,
        trackers_file=args.trackers_file,
        request_timeout_seconds=args.request_timeout_seconds,
        policy=Policy(
            minimum_age_days=args.minimum_age_days,
            minimum_ratio=args.minimum_ratio,
            maximum_age_days=args.maximum_age_days,
        ),
        delete=args.delete,
    )
    client = TransmissionClient(
        TransmissionRpcClient(
            rpc_url=settings.rpc_url,
            timeout_seconds=settings.request_timeout_seconds,
        )
    )
    try:
        return run_cleanup(settings, client, SystemClock())
    except FileNotFoundError as exc:
        LOG.error("required file is missing: %s", exc)
    except OSError as exc:
        LOG.error("failed to read tracker host file: %s", exc)
    except TransmissionRpcError as exc:
        LOG.error("cleanup run failed after Transmission RPC error: %s", exc)
    except KeyboardInterrupt:
        print("", file=sys.stderr)
        return 130
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
