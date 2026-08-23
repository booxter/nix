from __future__ import annotations

from pathlib import Path

import pytest

from nix_builder_metrics.cli import main, setup_main


def test_main_writes_successful_cgroup_sample(tmp_path: Path) -> None:
    root = tmp_path / "cgroup"
    daemon = root / "nix-daemon"
    daemon.mkdir(parents=True)
    (daemon / "cgroup.procs").write_text("1\n")
    output = tmp_path / "metrics.prom"

    result = main(
        [
            "--configured-slots",
            "4",
            "--cgroup-root",
            str(root),
            "--output-file",
            str(output),
        ]
    )

    assert result == 0
    assert "host_observability_nix_builder_collect_success 1.0" in output.read_text()


def test_main_writes_failed_sample_and_reports_error(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    output = tmp_path / "metrics.prom"

    result = main(
        [
            "--configured-slots",
            "2",
            "--cgroup-root",
            str(tmp_path / "missing"),
            "--output-file",
            str(output),
        ]
    )

    assert result == 1
    assert "host_observability_nix_builder_collect_success 0.0" in output.read_text()
    assert "Nix daemon cgroup is absent" in capsys.readouterr().err


def test_setup_main_enables_delegated_controllers(tmp_path: Path) -> None:
    (tmp_path / "cgroup.procs").write_text("")
    (tmp_path / "cgroup.controllers").write_text("io memory pids\n")
    subtree = tmp_path / "cgroup.subtree_control"
    subtree.write_text("")

    result = setup_main(["--cgroup-root", str(tmp_path)])

    assert result == 0
    assert subtree.read_text() == "+io +memory +pids\n"
