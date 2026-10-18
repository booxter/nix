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
    assert report["extra_nixpkgs_config"] == {"allowBroken": False, "cudaSupport": True}
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


@pytest.mark.parametrize(
    "build_arguments",
    [
        ["--build-args=--cores 2 --max-jobs 1"],
        ["--build-args", "--cores 2 --max-jobs 1"],
        ["--build-args=--cores 2", "--build-args=--max-jobs 1"],
    ],
)
def test_build_options_preserve_fleet_and_package_selection(
    review_environment: dict[str, str], build_arguments: list[str]
) -> None:
    builders = "ssh-ng://fleet-builder aarch64-linux - 4 100 - - -"
    environment = review_environment | {"NR_BUILDERS": builders}
    result = subprocess.run(
        [
            sys.executable,
            "-c",
            "from nr.cli import main; raise SystemExit(main())",
            "569298",
            "--",
            "-p",
            "python314Packages.pysail",
            *build_arguments,
        ],
        env=environment,
        check=False,
    )

    assert result.returncode == 0
    report = json.loads(Path(environment["NR_TEST_REPORT"]).read_text())
    assert report["builders"] == builders
    assert report["cores"] == 2
    assert report["max_jobs"] == 1
    assert report["package"] == ["python314Packages.pysail"]
    assert report["extra_nixpkgs_config"] == {"allowBroken": False}


@pytest.mark.parametrize("cuda_arguments", [[], ["-C"]])
@pytest.mark.parametrize(
    "config_arguments",
    [
        ["--extra-nixpkgs-config={ allowBroken = true; cudaSupport = false; }"],
        ["--extra-nixpkgs-config", "{ allowBroken = true; cudaSupport = false; }"],
    ],
)
def test_explicit_nixpkgs_config_overrides_defaults(
    review_environment: dict[str, str],
    cuda_arguments: list[str],
    config_arguments: list[str],
) -> None:
    result = subprocess.run(
        [
            sys.executable,
            "-c",
            "from nr.cli import main; raise SystemExit(main())",
            *cuda_arguments,
            "575183",
            "--",
            *config_arguments,
        ],
        env=review_environment,
        check=False,
    )

    assert result.returncode == 0
    report = json.loads(Path(review_environment["NR_TEST_REPORT"]).read_text())
    assert report["extra_nixpkgs_config"] == {"allowBroken": True, "cudaSupport": False}


def test_explicit_builders_override_fleet_defaults(
    review_environment: dict[str, str],
) -> None:
    builders = "ssh-ng://chosen-builder aarch64-linux '/key with spaces' 1"
    environment = review_environment | {"NR_BUILDERS": "ssh-ng://fleet-builder aarch64-linux"}
    result = subprocess.run(
        [
            sys.executable,
            "-c",
            "from nr.cli import main; raise SystemExit(main())",
            "569298",
            "--",
            f'--build-args=--builders "{builders}"',
        ],
        env=environment,
        check=False,
    )

    assert result.returncode == 0
    report = json.loads(Path(environment["NR_TEST_REPORT"]).read_text())
    assert report["builders"] == builders


@pytest.mark.parametrize("build_arguments", [["--build-args"], ["--build-args='"]])
def test_invalid_build_options_fail_before_starting_review(
    review_environment: dict[str, str], build_arguments: list[str]
) -> None:
    result = subprocess.run(
        [
            sys.executable,
            "-c",
            "from nr.cli import main; raise SystemExit(main())",
            "569298",
            "--",
            *build_arguments,
        ],
        env=review_environment,
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 1
    assert "nr:" in result.stderr
    assert not Path(review_environment["NR_TEST_REPORT"]).exists()
