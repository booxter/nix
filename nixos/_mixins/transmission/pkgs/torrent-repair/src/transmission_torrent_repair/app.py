import argparse
import logging
import re
from collections.abc import Sequence
from typing import Protocol

from pydantic import BaseModel, ConfigDict, Field, ValidationError
from transmission_common.transmission import TransmissionRpcClient, TransmissionRpcError

LOG = logging.getLogger("transmission-torrent-repair")
# RPC exposes only a generic local-error code. Match the specific message so
# disk-full, permission, and missing-data errors do not trigger verification.
# https://github.com/transmission/transmission/blob/4.1.0/libtransmission/peer-msgs.cc#L1889
CORRUPTION_ERROR = re.compile(r"Please Verify Local Data! Piece #[0-9]+ is corrupt\.")


class Torrent(BaseModel):
    model_config = ConfigDict(extra="ignore", frozen=True, strict=True)

    hash_string: str = Field(min_length=1)
    status: int
    error: int
    error_string: str

    def needs_verification(self) -> bool:
        # Local errors use code 3; states 1 and 2 are queued/active verification.
        return (
            self.error == 3
            and self.status not in (1, 2)
            and CORRUPTION_ERROR.fullmatch(self.error_string) is not None
        )


class TorrentList(BaseModel):
    model_config = ConfigDict(strict=True)

    torrents: list[Torrent]


class RpcTransport(Protocol):
    def call(self, method: str, params: dict[str, object]) -> dict[str, object]: ...


def repair(rpc: RpcTransport) -> int:
    response = rpc.call(
        "torrent_get", {"fields": ["hash_string", "status", "error", "error_string"]}
    )
    torrents = TorrentList.model_validate(response).torrents
    hashes = [torrent.hash_string for torrent in torrents if torrent.needs_verification()]
    if hashes:
        rpc.call("torrent_verify", {"ids": hashes})
        LOG.info("Requested verification for %d corrupt torrents", len(hashes))
    return len(hashes)


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Verify torrents reporting corrupt local data")
    parser.add_argument("--rpc-url", required=True)
    args = parser.parse_args(argv)
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")

    try:
        repair(TransmissionRpcClient(args.rpc_url, timeout_seconds=20))
    except (TransmissionRpcError, ValidationError) as exc:
        LOG.error("Could not request torrent verification: %s", exc)
        return 1
    return 0
