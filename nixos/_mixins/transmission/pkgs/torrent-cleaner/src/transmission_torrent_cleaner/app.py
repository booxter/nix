import argparse
import logging
import sys
import time
from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol

from pydantic import BaseModel, ConfigDict, Field, ValidationError, model_validator
from transmission_common.policy import (
    PolicyConfigError,
    TorrentPolicy,
    cleanup_reasons,
    load_policy,
    validate_tracker_aliases,
)
from transmission_common.transmission import (
    Tracker,
    TransmissionRpcClient,
    TransmissionRpcError,
    matching_tracker_aliases,
    normalize_tracker_host,
    read_tracker_aliases,
)

from .history import FileHistoryStore, HistoryError, HistoryStore, UploadHistory, observe_upload

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
    "uploaded_ever",
    "seconds_seeding",
]


class Torrent(BaseModel):
    model_config = ConfigDict(extra="allow", frozen=True, strict=True)

    hash_string: str = ""
    name: str = ""
    added_date: int = 0
    done_date: int = 0
    left_until_done: int | None = None
    percent_done: int | float | None = None
    size_when_done: int = Field(default=0, ge=0)
    tracker_stats: list[Tracker]
    upload_ratio: int | float | None = None
    uploaded_ever: int | None = Field(default=None, ge=0)
    seconds_seeding: int | None = Field(default=None, ge=0)

    @model_validator(mode="after")
    def validate_tracker_identity(self) -> "Torrent":
        # An empty list is valid for DHT-only torrents. An unidentified tracker
        # must not silently turn a special torrent into a generic candidate.
        for tracker in self.tracker_stats:
            if not any(
                raw_host and normalize_tracker_host(raw_host)
                for raw_host in (tracker.host, tracker.announce)
            ):
                raise ValueError("tracker identity unavailable")
        return self


class TorrentList(BaseModel):
    model_config = ConfigDict(extra="allow", frozen=True, strict=True)

    torrents: list[Torrent] = Field(default_factory=list)


@dataclass(frozen=True)
class Settings:
    rpc_url: str
    trackers_file: Path
    request_timeout_seconds: float
    policy: TorrentPolicy
    delete: bool


@dataclass(frozen=True)
class Candidate:
    hash: str
    name: str
    ratio: float | None
    age_days: float
    reasons: tuple[str, ...]
    size_bytes: int
    aliases: tuple[str, ...] = ()
    upload_bytes_per_second: float | None = None
    seed_days: float | None = None


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
            raise TransmissionRpcError("Transmission RPC returned an invalid torrent list") from exc

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
    return torrent.left_until_done == 0 and torrent.done_date > 0


def torrent_added_timestamp(torrent: Torrent) -> int | None:
    if torrent.added_date > 0:
        return torrent.added_date
    if torrent.done_date > 0:
        return torrent.done_date
    return None


def cleanup_candidate(
    torrent: Torrent,
    aliases: set[str],
    policy: TorrentPolicy,
    now: float,
    rate: float | None,
) -> Candidate | None:
    if not torrent.hash_string or not torrent.name or not torrent_is_complete(torrent):
        return None

    completion_age_days = (now - torrent.done_date) / DAY_SECONDS
    added_timestamp = torrent_added_timestamp(torrent)
    added_age_days = None if added_timestamp is None else (now - added_timestamp) / DAY_SECONDS
    seed_days = None if torrent.seconds_seeding is None else torrent.seconds_seeding / DAY_SECONDS
    reasons: tuple[str, ...]
    if aliases:
        if (
            seed_days is None
            or rate is None
            or rate >= policy.activity.minimum_upload_bytes_per_second
        ):
            return None
        if any(
            completion_age_days < policy.trackers[alias].minimum_age_days
            or seed_days < policy.trackers[alias].minimum_seed_days
            for alias in aliases
        ):
            return None
        reasons = ("low-upload",)
    else:
        reasons = cleanup_reasons(
            policy.non_preferred.cleanup,
            ratio=torrent.upload_ratio,
            complete=True,
            completion_age_days=completion_age_days,
            added_age_days=added_age_days,
        )
    if not reasons:
        return None
    return Candidate(
        hash=torrent.hash_string,
        name=torrent.name,
        ratio=None if torrent.upload_ratio is None else float(torrent.upload_ratio),
        age_days=completion_age_days,
        reasons=reasons,
        size_bytes=torrent.size_when_done,
        aliases=tuple(sorted(aliases)),
        upload_bytes_per_second=rate,
        seed_days=seed_days,
    )


def select_candidates(
    torrents: Sequence[Torrent],
    tracker_aliases: dict[str, str],
    policy: TorrentPolicy,
    now: float,
    upload_rates: dict[str, float],
) -> list[Candidate]:
    validate_tracker_aliases(policy, tracker_aliases)
    candidates: list[Candidate] = []
    remaining = dict.fromkeys(policy.trackers, 0)
    for torrent in torrents:
        aliases = matching_tracker_aliases(torrent.tracker_stats, tracker_aliases)
        if torrent_is_complete(torrent):
            for alias in aliases:
                remaining[alias] += 1
        candidate = cleanup_candidate(
            torrent, aliases, policy, now, upload_rates.get(torrent.hash_string)
        )
        if candidate is not None:
            candidates.append(candidate)

    selected: list[Candidate] = []
    for candidate in sorted(candidates, key=lambda item: (-item.age_days, item.hash)):
        # Account for every matched tracker after each selection, including
        # torrents shared by trackers with different retention floors.
        if any(
            remaining[alias] <= policy.trackers[alias].minimum_retained
            for alias in candidate.aliases
        ):
            continue
        selected.append(candidate)
        for alias in candidate.aliases:
            remaining[alias] -= 1
    return selected


def format_size_gib(size_bytes: int) -> str:
    return f"{size_bytes / (1024.0**3):.2f} GiB"


def format_age_days(age_days: float) -> str:
    return f"{age_days:.1f}d"


def collect_upload_history(
    torrents: Sequence[Torrent], history: UploadHistory, policy: TorrentPolicy, now: float
) -> tuple[UploadHistory, dict[str, float]]:
    updated = UploadHistory()
    rates: dict[str, float] = {}
    for torrent in torrents:
        if (
            not torrent.hash_string
            or not torrent_is_complete(torrent)
            or torrent.uploaded_ever is None
        ):
            continue
        observations, rate = observe_upload(
            history.torrents.get(torrent.hash_string),
            completed_at=torrent.done_date,
            uploaded_bytes=torrent.uploaded_ever,
            now=now,
            window_seconds=policy.activity.window_days * DAY_SECONDS,
        )
        updated.torrents[torrent.hash_string] = observations
        if rate is not None:
            rates[torrent.hash_string] = rate
    return updated, rates


def run_cleanup(
    settings: Settings, client: TorrentClient, clock: Clock, history_store: HistoryStore
) -> int:
    tracker_aliases = read_tracker_aliases(settings.trackers_file)
    validate_tracker_aliases(settings.policy, tracker_aliases)
    torrents = client.list_torrents()
    now = clock.now()
    history, rates = collect_upload_history(torrents, history_store.load(), settings.policy, now)
    # Save observations in dry-run mode too, and never delete after a failed save.
    history_store.save(history)
    candidates = select_candidates(torrents, tracker_aliases, settings.policy, now, rates)
    mode = "delete" if settings.delete else "dry-run"

    LOG.info(
        "scan complete: torrents=%s tracker_aliases=%s eligible=%s mode=%s history_ready=%s",
        len(torrents),
        len(tracker_aliases),
        len(candidates),
        mode,
        len(rates),
    )
    if not candidates:
        return 0

    for candidate in candidates:
        LOG.info(
            "%s candidate: reasons=%s hash=%s aliases=%s ratio=%s age=%s "
            "seed_days=%s upload_bytes_per_second=%s size=%s",
            "delete" if settings.delete else "would delete",
            ",".join(candidate.reasons),
            candidate.hash,
            ",".join(candidate.aliases) or "generic",
            f"{candidate.ratio:.2f}" if candidate.ratio is not None else "n/a",
            format_age_days(candidate.age_days),
            candidate.seed_days,
            candidate.upload_bytes_per_second,
            format_size_gib(candidate.size_bytes),
        )

    LOG.info(
        "%s summary: count=%s total_size=%s",
        "delete" if settings.delete else "dry-run",
        len(candidates),
        format_size_gib(sum(candidate.size_bytes for candidate in candidates)),
    )
    if settings.delete:
        # Recheck completion, obligations, activity and floors against a fresh
        # snapshot before removal; downloads may have changed during the scan.
        fresh_torrents = client.list_torrents()
        fresh_now = clock.now()
        fresh_history, fresh_rates = collect_upload_history(
            fresh_torrents, history, settings.policy, fresh_now
        )
        history_store.save(fresh_history)
        fresh_candidates = select_candidates(
            fresh_torrents, tracker_aliases, settings.policy, fresh_now, fresh_rates
        )
        planned = {candidate.hash for candidate in candidates}
        hashes = [candidate.hash for candidate in fresh_candidates if candidate.hash in planned]
        client.remove_torrents(hashes, delete_local_data=True)
        LOG.warning(
            "deleted %s torrent(s) with local data after matching cleanup policy",
            len(hashes),
        )
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="transmission-torrent-cleaner",
        description=(
            "Clean up old Transmission torrents while protecting productive seeds "
            "and tracker floors."
        ),
    )
    parser.add_argument("--rpc-url", default="http://127.0.0.1:9091/transmission/rpc")
    parser.add_argument("--trackers-file", required=True, type=Path)
    parser.add_argument("--policy-file", required=True, type=Path)
    parser.add_argument("--history-file", required=True, type=Path)
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
    try:
        settings = Settings(
            rpc_url=args.rpc_url,
            trackers_file=args.trackers_file,
            request_timeout_seconds=args.request_timeout_seconds,
            policy=load_policy(args.policy_file),
            delete=args.delete,
        )
        client = TransmissionClient(
            TransmissionRpcClient(
                rpc_url=settings.rpc_url,
                timeout_seconds=settings.request_timeout_seconds,
            )
        )
        return run_cleanup(settings, client, SystemClock(), FileHistoryStore(args.history_file))
    except FileNotFoundError as exc:
        LOG.error("required file is missing: %s", exc)
    except PolicyConfigError as exc:
        LOG.error("invalid policy configuration: %s", exc)
    except HistoryError as exc:
        LOG.error("%s", exc)
    except ValueError:
        LOG.error("invalid tracker aliases; cleanup skipped")
    except OSError as exc:
        LOG.error("cleanup storage or configuration unavailable: %s", exc)
    except TransmissionRpcError as exc:
        LOG.error("cleanup run failed after Transmission RPC error: %s", exc)
    except KeyboardInterrupt:
        print(file=sys.stderr)
        return 130
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
