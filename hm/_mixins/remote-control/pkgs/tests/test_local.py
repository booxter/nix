import io
from collections.abc import Mapping, Sequence
from typing import NoReturn

import pytest
from remote_nixpkgs.local import main
from remote_nixpkgs.runtime import RunError
from test_remote_nixpkgs import FakeProcessController, ProgramReplaced


@pytest.mark.parametrize("separator", [[], ["--"]])
def test_runs_pr_locally_with_program_arguments(separator: list[str]) -> None:
    with pytest.raises(ProgramReplaced) as replaced:
        main(
            ["538891", "hello", *separator, "--greeting", "two words"],
            process=FakeProcessController(),
            environment={"DISPLAY": "local-display"},
        )

    arguments = replaced.value.arguments
    assert "github:NixOS/nixpkgs?ref=pull/538891/head#hello" in arguments
    assert arguments[-3:] == ("--", "--greeting", "two words")
    assert replaced.value.environment["DISPLAY"] == "local-display"


@pytest.mark.parametrize(
    ("flags", "environment"),
    [
        (["--allow-unfree"], {}),
        ([], {"RUN_NIXPKGS_ALLOW_UNFREE": "yes"}),
    ],
)
def test_allows_unfree_packages(flags: list[str], environment: dict[str, str]) -> None:
    with pytest.raises(ProgramReplaced) as replaced:
        main(
            [*flags, "nixpkgs", "hello"],
            process=FakeProcessController(),
            environment=environment,
        )

    assert "--impure" in replaced.value.arguments
    assert replaced.value.environment["NIXPKGS_ALLOW_UNFREE"] == "1"


def test_reports_missing_package_argument() -> None:
    stderr = io.StringIO()

    status = main(["538891"], stderr=stderr)

    assert status == 64
    assert "run-nixpkgs:" in stderr.getvalue()
    assert "package_attribute" in stderr.getvalue()


class UnavailableNix(FakeProcessController):
    def replace(
        self,
        arguments: Sequence[str],
        environment: Mapping[str, str] | None = None,
    ) -> NoReturn:
        raise RunError("executable is not available: nix")


def test_reports_unavailable_nix() -> None:
    stderr = io.StringIO()

    status = main(["nixpkgs", "hello"], process=UnavailableNix(), stderr=stderr)

    assert status == 1
    assert "run-nixpkgs: executable is not available: nix" in stderr.getvalue()
