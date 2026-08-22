import io
from datetime import datetime, timezone
from pathlib import Path

from nixpkgs_cache_warmer.cli import run
from nixpkgs_cache_warmer.commands import CommandResult
from nixpkgs_cache_warmer.models import RunRecord, TargetState, WarmerState
from nixpkgs_cache_warmer.state import StateStore


class FakeRunner:
    def __init__(self, result: CommandResult) -> None:
        self.result = result

    def run(self, arguments: tuple[str, ...] | list[str]) -> CommandResult:
        return self.result


class SequencedRunner:
    def __init__(self, results: list[CommandResult]) -> None:
        self.results = results
        self.calls: list[tuple[str, ...]] = []

    def run(self, arguments: tuple[str, ...] | list[str]) -> CommandResult:
        self.calls.append(tuple(arguments))
        return self.results.pop(0)

    def run_streaming(
        self, arguments: tuple[str, ...] | list[str], stderr: io.StringIO
    ) -> CommandResult:
        result = self.run(arguments)
        stderr.write(result.stderr)
        return CommandResult(result.returncode, result.stdout, "")


ENVIRONMENT = {
    "NIXPKGS_CACHE_WARMER_NIX": "/nix",
    "NIXPKGS_CACHE_WARMER_NIX_INSTANTIATE": "/nix-instantiate",
    "NIXPKGS_CACHE_WARMER_INVENTORY_EXPR": "/inventory.nix",
    "NIXPKGS_CACHE_WARMER_STATE_FILE": "/state.json",
    "NIXPKGS_CACHE_WARMER_SSH": "/ssh",
}


def test_resolve_prints_revision() -> None:
    stdout = io.StringIO()
    status = run(
        ["resolve", "github:NixOS/nixpkgs/staging"],
        ENVIRONMENT,
        FakeRunner(
            CommandResult(
                0,
                '{"locked":{"rev":"012345"},"path":"/nix/store/source"}',
                "",
            )
        ),
        stdout,
        io.StringIO(),
    )

    assert status == 0
    assert stdout.getvalue() == "012345\t/nix/store/source\n"


def test_resolve_prints_json() -> None:
    stdout = io.StringIO()
    status = run(
        ["resolve", "github:NixOS/nixpkgs/staging", "--json"],
        ENVIRONMENT,
        FakeRunner(
            CommandResult(
                0,
                '{"locked":{"rev":"012345"},"path":"/nix/store/source"}',
                "",
            )
        ),
        stdout,
        io.StringIO(),
    )

    assert status == 0
    assert '"revision": "012345"' in stdout.getvalue()


def test_warm_reports_success(tmp_path: Path) -> None:
    runner = SequencedRunner(
        [
            CommandResult(
                0,
                '{"locked":{"rev":"012345"},"path":"/nix/store/source"}',
                "",
            ),
            CommandResult(
                0,
                '[{"drvPath":"/nix/store/a.drv","name":"one-1","pname":"one",'
                '"outputs":["/nix/store/one"]}]',
                "",
            ),
            CommandResult(0, "/nix/store/a.drv\n", ""),
            CommandResult(0, "/nix/store/one\n", ""),
        ]
    )
    stderr = io.StringIO()
    status = run(
        [
            "warm",
            "github:NixOS/nixpkgs/staging",
            "--maintainer",
            "booxter",
            "--system",
            "x86_64-linux",
        ],
        ENVIRONMENT | {"NIXPKGS_CACHE_WARMER_STATE_FILE": str(tmp_path / "state.json")},
        runner,
        io.StringIO(),
        stderr,
    )

    assert status == 0
    assert "Built 1/1" in stderr.getvalue()
    state = StateStore(tmp_path / "state.json").read()
    assert state.targets[0].last_success is not None
    assert state.targets[0].last_success.revision == "012345"


def test_run_builds_complete_matrix_with_one_nix_invocation(tmp_path: Path) -> None:
    runner = SequencedRunner(
        [
            CommandResult(
                0,
                '{"locked":{"rev":"012345"},"path":"/nix/store/source"}',
                "",
            ),
            CommandResult(
                0,
                '[{"drvPath":"/nix/store/a.drv","name":"one-1","pname":"one",'
                '"outputs":["/nix/store/one"]}]',
                "",
            ),
            CommandResult(0, "/nix/store/a.drv\n", ""),
            CommandResult(
                0,
                '[{"drvPath":"/nix/store/b.drv","name":"two-1","pname":"two",'
                '"outputs":["/nix/store/two"]}]',
                "",
            ),
            CommandResult(0, "/nix/store/b.drv\n", ""),
            CommandResult(0, "/nix/store/one\n/nix/store/two\n", ""),
        ]
    )

    status = run(
        [
            "run",
            "--reference",
            "github:NixOS/nixpkgs/staging",
            "--maintainer",
            "booxter",
            "--system",
            "aarch64-darwin",
            "--system",
            "x86_64-linux",
        ],
        ENVIRONMENT | {"NIXPKGS_CACHE_WARMER_STATE_FILE": str(tmp_path / "state.json")},
        runner,
        io.StringIO(),
        io.StringIO(),
    )

    assert status == 0
    build_calls = [call for call in runner.calls if len(call) > 1 and call[1] == "build"]
    assert len(build_calls) == 1
    assert set(build_calls[0][-2:]) == {
        "/nix/store/a.drv^*",
        "/nix/store/b.drv^*",
    }
    state = StateStore(tmp_path / "state.json").read()
    assert [target.system for target in state.targets] == ["aarch64-darwin", "x86_64-linux"]


def test_status_prints_last_attempt_and_success(tmp_path: Path) -> None:
    record = RunRecord(
        attempted_at=datetime(2026, 8, 21, tzinfo=timezone.utc),
        revision="012345",
        status="success",
        selected=2,
        built=2,
        failed=0,
    )
    StateStore(tmp_path / "status.json").write(
        WarmerState(
            targets=(
                TargetState(
                    reference="github:NixOS/nixpkgs/staging",
                    system="x86_64-linux",
                    last_attempt=record,
                    last_success=record,
                ),
            )
        )
    )
    stdout = io.StringIO()

    status = run(
        [
            "status",
            "--state-file",
            str(tmp_path / "status.json"),
            "--branch",
            "staging",
            "--system",
            "x86_64-linux",
        ],
        ENVIRONMENT,
        FakeRunner(CommandResult(0, "", "")),
        stdout,
        io.StringIO(),
    )

    assert status == 0
    assert stdout.getvalue() == (
        "staging\tx86_64-linux\t012345\tsuccess\t2/2\tlast-success=012345\n"
    )


def test_status_prints_single_successful_revision(tmp_path: Path) -> None:
    record = RunRecord(
        attempted_at=datetime(2026, 8, 21, tzinfo=timezone.utc),
        revision="012345",
        status="success",
        selected=1,
        built=1,
        failed=0,
    )
    StateStore(tmp_path / "status.json").write(
        WarmerState(
            targets=(
                TargetState(
                    reference="github:NixOS/nixpkgs/staging",
                    system="aarch64-darwin",
                    last_attempt=record,
                    last_success=record,
                ),
            )
        )
    )
    stdout = io.StringIO()

    status = run(
        [
            "status",
            "--state-file",
            str(tmp_path / "status.json"),
            "--print-revision",
        ],
        ENVIRONMENT,
        FakeRunner(CommandResult(0, "", "")),
        stdout,
        io.StringIO(),
    )

    assert status == 0
    assert stdout.getvalue() == "012345\n"


def test_status_reads_authoritative_runner() -> None:
    record = RunRecord(
        attempted_at=datetime(2026, 8, 21, tzinfo=timezone.utc),
        revision="012345",
        status="success",
        selected=1,
        built=1,
        failed=0,
    )
    remote_state = WarmerState(
        targets=(
            TargetState(
                reference="github:NixOS/nixpkgs/staging",
                system="x86_64-linux",
                last_attempt=record,
                last_success=record,
            ),
        )
    ).model_dump_json()
    stdout = io.StringIO()
    stderr = io.StringIO()

    status = run(
        [
            "status",
            "--branch",
            "staging",
            "--system",
            "x86_64-linux",
            "--print-revision",
        ],
        ENVIRONMENT | {"NIXPKGS_CACHE_WARMER_RUNNER": "mmini"},
        FakeRunner(CommandResult(0, remote_state, "")),
        stdout,
        stderr,
    )

    assert status == 0, stderr.getvalue()
    assert stdout.getvalue() == "012345\n"


def test_targets_prints_human_inventory() -> None:
    stdout = io.StringIO()
    status = run(
        ["targets", "--source", "/source", "--maintainer", "booxter", "--system", "x86_64-linux"],
        ENVIRONMENT,
        FakeRunner(
            CommandResult(
                0,
                '[{"drvPath":"/nix/store/a.drv","name":"one-1","pname":"one",'
                '"outputs":["/nix/store/one"]}]',
                "",
            )
        ),
        stdout,
        io.StringIO(),
    )

    assert status == 0
    assert stdout.getvalue() == "one\t/nix/store/a.drv\n"


def test_targets_prints_json_inventory() -> None:
    stdout = io.StringIO()
    status = run(
        [
            "targets",
            "--source",
            "/source",
            "--maintainer",
            "booxter",
            "--system",
            "x86_64-linux",
            "--json",
        ],
        ENVIRONMENT,
        FakeRunner(CommandResult(0, "[]", "")),
        stdout,
        io.StringIO(),
    )

    assert status == 0
    assert stdout.getvalue() == "[]\n"


def test_targets_reports_missing_packaged_configuration() -> None:
    stderr = io.StringIO()
    status = run(
        ["targets", "--source", "/source", "--maintainer", "booxter", "--system", "x86_64-linux"],
        {},
        FakeRunner(CommandResult(0, "[]", "")),
        io.StringIO(),
        stderr,
    )

    assert status == 2
    assert "missing packaged setting" in stderr.getvalue()


def test_targets_reports_nix_failure() -> None:
    stderr = io.StringIO()
    status = run(
        [
            "targets",
            "--source",
            str(Path("/source")),
            "--maintainer",
            "booxter",
            "--system",
            "x86_64-linux",
        ],
        ENVIRONMENT,
        FakeRunner(CommandResult(1, "", "failed")),
        io.StringIO(),
        stderr,
    )

    assert status == 1
    assert "Nix evaluation failed" in stderr.getvalue()
