import json
import subprocess
import sys
from pathlib import Path

import pytest


@pytest.mark.parametrize("builders", [None, "", "ssh://builder aarch64-linux '/a path/key' 4"])
def test_review_process_receives_choices_and_returns_failure(
    review_environment: dict[str, str], builders: str | None
) -> None:
    environment = review_environment | {"NR_TEST_STATUS": "7"}
    options = ["-p", "-a", "-t", "-C", "-i", "122", "-s", "aarch64-linux", "123"]
    if builders is not None:
        environment["NR_LOCAL_BUILDERS"] = builders
        options.append("-l")
    else:
        environment.pop("NR_BUILDERS", None)

    result = subprocess.run(
        [sys.executable, "-c", "from nr.cli import main; raise SystemExit(main())", *options],
        env=environment,
        check=False,
    )

    assert result.returncode == 7
    report = json.loads(Path(environment["NR_TEST_REPORT"]).read_text())
    assert report["pull_requests"] == ["123"]
    assert report["include_pr"] == ["122"]
    assert report["systems"] == "aarch64-linux"
    assert report["post_result"]
    assert report["approve_pr"]
    assert report["tests"]
    assert report["no_shell"]
    assert "cudaSupport = true" in report["extra_nixpkgs_config"]
    assert report["builders"] == builders


def test_minimal_review_runs_successfully(review_environment: dict[str, str]) -> None:
    result = subprocess.run(
        [sys.executable, "-c", "from nr.cli import main; raise SystemExit(main())", "123"],
        env=review_environment,
        check=False,
    )

    assert result.returncode == 0


def test_package_selection_after_separator_reaches_review(
    review_environment: dict[str, str],
) -> None:
    result = subprocess.run(
        [
            sys.executable,
            "-c",
            "from nr.cli import main; raise SystemExit(main())",
            "-s",
            "x86_64-linux aarch64-darwin",
            "572768",
            "--",
            "-p",
            "llvmPackages_21.llvm",
        ],
        env=review_environment,
        check=False,
    )

    assert result.returncode == 0
    report = json.loads(Path(review_environment["NR_TEST_REPORT"]).read_text())
    assert report["pull_requests"] == ["572768"]
    assert report["package"] == ["llvmPackages_21.llvm"]
    assert report["systems"] == "x86_64-linux aarch64-darwin"
    assert not report["post_result"]
