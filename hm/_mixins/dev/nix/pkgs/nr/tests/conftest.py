import os
import sys
import tempfile
from collections.abc import Iterator
from pathlib import Path

import pytest
from nr.process import ProcessRunner


@pytest.fixture
def review_environment(tmp_path: Path) -> Iterator[dict[str, str]]:
    executable = tmp_path / "nixpkgs-review"
    source = Path(__file__).with_name("review_stub.py").read_text()
    executable.write_text(f"#!{sys.executable}\n{source}")
    executable.chmod(0o755)

    # Raw Nix interpreters do not process dependency .pth files from
    # PYTHONPATH, so start subprocess coverage explicitly.
    (tmp_path / "sitecustomize.py").write_text("import coverage\ncoverage.process_startup()\n")
    yield {
        **os.environ,
        "PATH": f"{tmp_path}{os.pathsep}{os.environ['PATH']}",
        # Nix's pytest wrapper adds dependency paths at startup. Give child
        # interpreters the same imports, including the package under test.
        "PYTHONPATH": os.pathsep.join([str(tmp_path), *sys.path]),
        "NR_TEST_REPORT": str(tmp_path / "report.json"),
    }


@pytest.fixture
def tmux_environment(review_environment: dict[str, str]) -> Iterator[dict[str, str]]:
    # Keep the socket path short enough for Darwin's Unix socket limit.
    with tempfile.TemporaryDirectory(prefix="nr-") as directory:
        environment = review_environment | {"TMUX_TMPDIR": directory, "HOME": directory}
        environment.pop("TMUX", None)
        environment.pop("TMUX_PANE", None)
        yield environment
        ProcessRunner(environment).run(["tmux", "kill-server"])


@pytest.fixture
def helpers(tmp_path: Path) -> Path:
    for name, module in (("nr-submit", "tmux"), ("nr-worker", "worker")):
        executable = tmp_path / name
        executable.write_text(
            f"#!{sys.executable}\nfrom nr.{module} import main\nraise SystemExit(main())\n"
        )
        executable.chmod(0o755)
    return tmp_path


@pytest.fixture
def checkout(tmp_path: Path) -> Path:
    path = tmp_path / "checkout with spaces"
    (path / "nixos").mkdir(parents=True)
    (path / "nixos" / "release.nix").touch()
    runner = ProcessRunner()
    runner.run(["git", "init", str(path)]).check_returncode()
    runner.run(["git", "add", "."], cwd=path).check_returncode()
    runner.run(
        [
            "git",
            "-c",
            "user.name=Test",
            "-c",
            "user.email=test@example.invalid",
            "-c",
            "commit.gpgsign=false",
            "commit",
            "-m",
            "Fixture",
        ],
        cwd=path,
    ).check_returncode()
    return path
