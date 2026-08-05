import argparse
import io
import json

import pytest

from package_updates.nodejs import main, run, select_nodejs

CANDIDATES = {
    "nodejs_20": "20.20.2",
    "nodejs_22": "22.23.1",
    "nodejs_24": "24.18.0",
    "nodejs_26": "26.5.1",
    "nodejs_broken": "development",
}


def test_selects_required_node_line() -> None:
    selection = select_nodejs("22.23.x", CANDIDATES, "nodejs_24")
    assert selection.attribute == "nodejs_22"
    assert selection.version == "22.23.1"


def test_keeps_compatible_current_node_line() -> None:
    assert select_nodejs(">=22 <26", CANDIDATES, "nodejs_24").attribute == "nodejs_24"


def test_selects_newest_compatible_version() -> None:
    assert select_nodejs(">=20 <25", CANDIDATES, "missing").attribute == "nodejs_24"


def test_reports_missing_compatible_node_line() -> None:
    with pytest.raises(ValueError, match="no available nixpkgs Node.js version satisfies"):
        select_nodejs("23.x", CANDIDATES, "nodejs_24")


def test_cli_emits_compact_typed_json() -> None:
    stdout = io.StringIO()
    stderr = io.StringIO()
    status = run(
        argparse.Namespace(
            requirement="22.x",
            current_attribute="nodejs_20",
            candidates_json=json.dumps(CANDIDATES),
        ),
        stdout,
        stderr,
    )
    assert status == 0
    assert json.loads(stdout.getvalue()) == {
        "attribute": "nodejs_22",
        "version": "22.23.1",
    }
    assert stderr.getvalue() == ""


def test_cli_rejects_invalid_candidate_payload() -> None:
    stderr = io.StringIO()
    status = run(
        argparse.Namespace(
            requirement="22.x",
            current_attribute="nodejs_20",
            candidates_json="[]",
        ),
        io.StringIO(),
        stderr,
    )
    assert status == 1
    assert "cannot select Node.js" in stderr.getvalue()


def test_console_entrypoint_parses_arguments(capsys: pytest.CaptureFixture[str]) -> None:
    assert (
        main(
            [
                "--requirement",
                "22.x",
                "--current-attribute",
                "nodejs_20",
                "--candidates-json",
                json.dumps(CANDIDATES),
            ]
        )
        == 0
    )
    assert json.loads(capsys.readouterr().out)["attribute"] == "nodejs_22"
