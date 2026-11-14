import json
import subprocess
from collections.abc import Mapping, Sequence
from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from threading import Thread

import pytest
import tomli_w
from ci_build.cli import NativeCommands, main

OUTPUT = "/nix/store/" + "a" * 32 + "-result"
DEV = "/nix/store/" + "b" * 32 + "-dev"
UNRELATED = "/nix/store/" + "c" * 32 + "-manual-build"


@dataclass
class FakeCommands:
    result: str = field(default_factory=lambda: json.dumps([{"outputs": {"out": OUTPUT}}]))
    build_error: Exception | None = None
    upload_error: Exception | None = None
    uploads: list[str] = field(default_factory=list)
    builds: int = 0

    def capture(self, arguments: Sequence[str]) -> str:
        self.builds += 1
        if self.build_error:
            raise self.build_error
        return self.result

    def run(self, arguments: Sequence[str], *, env: Mapping[str, str] | None = None) -> None:
        if self.upload_error:
            raise self.upload_error
        self.uploads.extend(
            argument for argument in arguments if argument.startswith("/nix/store/")
        )


@pytest.fixture
def config(tmp_path: Path) -> str:
    path = tmp_path / "attic.toml"
    path.write_text("")
    return str(path)


def test_publishes_all_requested_outputs_including_existing_results(config: str) -> None:
    commands = FakeCommands(
        result=json.dumps([{"outputs": {"out": OUTPUT, "dev": DEV}}, {"outputs": {"out": OUTPUT}}])
    )
    assert main([".#first", ".#second"], config_file=config, commands=commands) == 0
    assert commands.uploads == [OUTPUT, DEV]
    assert UNRELATED not in commands.uploads


@pytest.mark.parametrize(
    "error", [subprocess.CalledProcessError(17, "nix"), OSError("missing nix")]
)
def test_build_failure_does_not_publish(config: str, error: Exception) -> None:
    commands = FakeCommands(build_error=error)
    assert main([".#target"], config_file=config, commands=commands) != 0
    assert commands.uploads == []


@pytest.mark.parametrize("status", [1, -15])
def test_upload_failure_fails_the_job(config: str, status: int) -> None:
    commands = FakeCommands(upload_error=subprocess.CalledProcessError(status, "attic"))
    assert main([".#target"], config_file=config, commands=commands) == 1


@pytest.mark.parametrize(
    "result",
    ["not json", "[]", '[{"outputs": {}}]', '[{"outputs": {"out": "/etc/shadow"}}]'],
)
def test_invalid_results_are_never_uploaded(config: str, result: str) -> None:
    commands = FakeCommands(result=result)
    assert main([".#target"], config_file=config, commands=commands) == 1
    assert commands.uploads == []


def test_missing_credential_prevents_building(tmp_path: Path) -> None:
    commands = FakeCommands()
    assert main([".#target"], config_file=str(tmp_path / "missing"), commands=commands) == 1
    assert commands.builds == 0


def test_native_commands_capture_output_and_report_failures() -> None:
    commands = NativeCommands()
    assert commands.capture(["printf", "result"]) == "result"
    commands.run(["true"])
    with pytest.raises(subprocess.CalledProcessError):
        commands.run(["false"])


def test_real_attic_uses_runner_credential(tmp_path: Path) -> None:
    requests: list[tuple[str, str | None]] = []

    class CacheServer(BaseHTTPRequestHandler):
        def do_GET(self) -> None:
            requests.append((self.path, self.headers.get("Authorization")))
            # Stop before any store paths are uploaded; only exercise client setup.
            self.send_error(403)

        def log_message(self, format: str, *args: object) -> None:
            pass

    class RealAtticCommands(FakeCommands):
        def run(self, arguments: Sequence[str], *, env: Mapping[str, str] | None = None) -> None:
            NativeCommands().run(arguments, env=dict(env or {}) | {"NIX_REMOTE": "dummy://"})

    with HTTPServer(("127.0.0.1", 0), CacheServer) as server:
        config = tmp_path / "runner.toml"
        config.write_text(
            tomli_w.dumps(
                {
                    "servers": {
                        "ci": {
                            "endpoint": f"http://127.0.0.1:{server.server_port}",
                            "token": "test-ci-token",
                        }
                    }
                }
            )
        )
        thread = Thread(target=server.serve_forever)
        thread.start()
        try:
            assert main([".#target"], config_file=str(config), commands=RealAtticCommands()) != 0
            assert len(requests) == 1
            path, authorization = requests[0]
            assert path == "/_api/v1/cache-config/github"
            assert authorization is not None
            scheme, token = authorization.split()
            assert scheme.lower() == "bearer"
            assert token == "test-ci-token"
        finally:
            server.shutdown()
            thread.join()
