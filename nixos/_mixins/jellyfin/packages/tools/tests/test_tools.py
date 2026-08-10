from __future__ import annotations

import io
import json
import os
import threading
from collections.abc import Iterator
from contextlib import contextmanager
from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import cast
from urllib.parse import urlsplit

import pytest

from jellyfin_tools.cli import run_backup, run_wait
from jellyfin_tools.service import JellyfinServiceError, create_backup_artifact
from jellyfin_tools.systemd import active_state

Response = tuple[int, object]


@dataclass
class ApiState:
    sessions: list[Response] = field(default_factory=lambda: [(200, [])])
    backup_response: Response = (200, {})
    authorizations: list[str | None] = field(default_factory=list)
    backup_payloads: list[dict[str, object]] = field(default_factory=list)

    @staticmethod
    def next_response(responses: list[Response]) -> Response:
        return responses.pop(0) if len(responses) > 1 else responses[0]


@contextmanager
def api_server(state: ApiState) -> Iterator[str]:
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self) -> None:
            state.authorizations.append(self.headers.get("Authorization"))
            if urlsplit(self.path).path == "/Sessions":
                response = state.next_response(state.sessions)
            else:
                response = (404, {"error": "not found"})
            self.respond(*response)

        def do_POST(self) -> None:
            state.authorizations.append(self.headers.get("Authorization"))
            length = int(self.headers.get("Content-Length", "0"))
            payload = cast(
                dict[str, object],
                json.loads(self.rfile.read(length) or b"{}"),
            )
            if urlsplit(self.path).path == "/Backup/Create":
                state.backup_payloads.append(payload)
                response = state.backup_response
            else:
                response = (404, {"error": "not found"})
            self.respond(*response)

        def respond(self, status: int, body: object) -> None:
            encoded = json.dumps(body).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(encoded)))
            self.end_headers()
            self.wfile.write(encoded)

        def log_message(self, format: str, *args: object) -> None:
            del format, args

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever)
    thread.start()
    try:
        host, port = server.server_address
        yield f"http://{host}:{port}"
    finally:
        server.shutdown()
        thread.join()
        server.server_close()


@dataclass
class SequenceUnitState:
    states: list[bool]

    def is_active(self, unit_name: str) -> bool:
        assert unit_name == "jellyfin.service"
        return self.states.pop(0) if len(self.states) > 1 else self.states[0]


def api_key(tmp_path: Path) -> Path:
    path = tmp_path / "api-key"
    path.write_text("jellyfin-key\n", encoding="utf-8")
    return path


def wait_arguments(base_url: str, key: Path) -> list[str]:
    return ["--url", base_url, "--api-key-file", str(key)]


def test_inactive_jellyfin_does_not_require_api_credentials(tmp_path: Path) -> None:
    run_wait(
        wait_arguments("http://127.0.0.1:1", tmp_path / "missing"),
        SequenceUnitState([False]),
        sleep=lambda _: None,
        stderr=io.StringIO(),
    )


def test_wait_reports_playback_then_allows_idle_maintenance(tmp_path: Path) -> None:
    state = ApiState(
        sessions=[
            (
                200,
                [
                    {
                        "UserName": "Alice",
                        "NowPlayingItem": {"Name": "A Film"},
                        "PlayState": {"IsPaused": False},
                    },
                    {
                        "UserName": "Bob",
                        "NowPlayingItem": {"Name": "An Episode"},
                        "PlayState": {"IsPaused": True},
                    },
                    {"UserName": "Idle"},
                ],
            ),
            (200, []),
        ]
    )
    sleeps: list[float] = []
    stderr = io.StringIO()
    with api_server(state) as base_url:
        run_wait(
            wait_arguments(base_url, api_key(tmp_path)),
            SequenceUnitState([True, True]),
            sleep=sleeps.append,
            stderr=stderr,
        )

    output = stderr.getvalue()
    assert "2 active Jellyfin playback session(s)" in output
    assert "Alice: A Film (playing)" in output
    assert "Bob: An Episode (paused)" in output
    assert sleeps == [30.0]
    assert all(
        authorization is not None and 'Token="jellyfin-key"' in authorization
        for authorization in state.authorizations
    )


def test_invalid_sessions_are_retried(tmp_path: Path) -> None:
    state = ApiState(sessions=[(200, {"not": "a list"}), (200, [])])
    sleeps: list[float] = []
    stderr = io.StringIO()
    with api_server(state) as base_url:
        run_wait(
            wait_arguments(base_url, api_key(tmp_path)),
            SequenceUnitState([True, True]),
            sleep=sleeps.append,
            stderr=stderr,
        )

    assert "Unable to query active Jellyfin sessions" in stderr.getvalue()
    assert sleeps == [30.0]


def create_archive(directory: Path, name: str, timestamp: int) -> Path:
    path = directory / name
    path.write_bytes(name.encode())
    os.utime(path, ns=(timestamp, timestamp))
    return path


def test_backup_uses_native_client_and_prunes_both_directories(tmp_path: Path) -> None:
    source_dir = tmp_path / "source"
    staging_dir = tmp_path / "staging"
    source_dir.mkdir()
    staging_dir.mkdir()
    for index in range(3):
        create_archive(source_dir, f"jellyfin-backup-old-{index}.zip", index + 1)
    for index in range(8):
        create_archive(staging_dir, f"jellyfin-backup-old-{index}.zip", index + 1)
    created = create_archive(source_dir, "jellyfin-backup-new.zip", 100)
    state = ApiState(backup_response=(200, {"Path": str(created)}))

    with api_server(state) as base_url:
        destination = run_backup(
            [
                "--url",
                base_url,
                "--api-key-file",
                str(api_key(tmp_path)),
                "--source-dir",
                str(source_dir),
                "--staging-dir",
                str(staging_dir),
                "--keep-staging",
                "7",
                "--keep-source",
                "1",
            ]
        )

    assert destination.read_bytes() == created.read_bytes()
    assert destination.stat().st_mode & 0o777 == 0o640
    assert len(tuple(staging_dir.glob("jellyfin-backup-*.zip"))) == 7
    assert tuple(source_dir.glob("jellyfin-backup-*.zip")) == (created,)
    assert state.backup_payloads == [
        {
            "database": True,
            "metadata": False,
            "subtitles": False,
            "trickplay": False,
        }
    ]


def test_backup_rejects_paths_outside_source_directory(tmp_path: Path) -> None:
    source_dir = tmp_path / "source"
    staging_dir = tmp_path / "staging"
    source_dir.mkdir()
    staging_dir.mkdir()
    outside = create_archive(tmp_path, "jellyfin-backup-outside.zip", 1)

    with pytest.raises(JellyfinServiceError, match="valid archive path"):
        create_backup_artifact(
            lambda: outside,
            source_dir=source_dir,
            staging_dir=staging_dir,
            keep_staging=7,
            keep_source=1,
        )


@pytest.mark.parametrize(
    ("value", "expected"),
    [(b"active", True), ("active", True), (b"inactive", False)],
)
def test_active_state(value: bytes | str, expected: bool) -> None:
    assert active_state(value) is expected
