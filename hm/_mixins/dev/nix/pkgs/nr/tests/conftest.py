import os
import sys
from collections.abc import Iterator
from pathlib import Path

import pytest


@pytest.fixture
def review_environment(tmp_path: Path) -> Iterator[dict[str, str]]:
    executable = tmp_path / "nixpkgs-review"
    source = Path(__file__).with_name("review_stub.py").read_text()
    executable.write_text(f"#!{sys.executable}\n{source}")
    executable.chmod(0o755)
    yield {
        **os.environ,
        "PATH": f"{tmp_path}{os.pathsep}{os.environ['PATH']}",
        "PYTHONPATH": str(Path(__file__).parents[1] / "src"),
        "NR_TEST_REPORT": str(tmp_path / "report.json"),
    }
