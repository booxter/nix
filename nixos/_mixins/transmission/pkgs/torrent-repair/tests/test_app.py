from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler, HTTPServer
from threading import Thread

import pytest
from pydantic import ValidationError
from transmission_common.transmission import TransmissionRpcError
from transmission_torrent_repair.app import Torrent, main, repair


def torrent(
    identity: str = "corrupt", *, status: int = 6, error: int = 3, message: str | None = None
) -> Torrent:
    return Torrent(
        hash_string=identity,
        status=status,
        error=error,
        error_string=message or "Please Verify Local Data! Piece #123 is corrupt.",
    )


@dataclass
class FakeTransmission:
    torrents: list[Torrent]
    verified: list[str] = field(default_factory=list)
    failure: bool = False

    def call(self, method: str, params: dict[str, object]) -> dict[str, object]:
        if self.failure:
            raise TransmissionRpcError("unavailable")
        if method == "torrent_get":
            return {"torrents": [item.model_dump() for item in self.torrents]}
        if method == "torrent_verify":
            identities = params["ids"]
            assert isinstance(identities, list)
            self.verified.extend(identities)
            return {}
        raise AssertionError(f"Unexpected operation: {method}")


def test_requests_verification_only_for_corruption() -> None:
    client = FakeTransmission(
        [
            torrent("corrupt"),
            torrent("queued", status=1),
            torrent("checking", status=2),
            torrent("healthy", error=0),
            torrent("tracker-error", error=2),
            torrent("missing-data", message="No data found!"),
            torrent("disk-error", message="Permission denied"),
        ]
    )

    assert repair(client) == 1
    assert client.verified == ["corrupt"]


def test_empty_queue_needs_no_verification() -> None:
    client = FakeTransmission([])

    assert repair(client) == 0
    assert client.verified == []


def test_rpc_failure_is_reported() -> None:
    with pytest.raises(TransmissionRpcError, match="unavailable"):
        repair(FakeTransmission([], failure=True))


def test_invalid_queue_response_is_rejected() -> None:
    class InvalidTransmission:
        def call(self, method: str, params: dict[str, object]) -> dict[str, object]:
            return {"torrents": [{"hash_string": "incomplete"}]}

    with pytest.raises(ValidationError):
        repair(InvalidTransmission())


def test_command_reports_connection_failure() -> None:
    class Unavailable(BaseHTTPRequestHandler):
        def do_POST(self) -> None:
            self.send_error(503)

    server = HTTPServer(("127.0.0.1", 0), Unavailable)
    thread = Thread(target=server.serve_forever)
    thread.start()
    try:
        assert main(["--rpc-url", f"http://127.0.0.1:{server.server_port}"]) == 1
    finally:
        server.shutdown()
        thread.join()
        server.server_close()
