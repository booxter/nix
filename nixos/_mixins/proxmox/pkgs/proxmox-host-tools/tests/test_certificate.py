from __future__ import annotations

import argparse
import io
from pathlib import Path

import pytest

from proxmox_host_tools.certificate import Error, Pmxcfs, positive_integer, run


def test_installs_certificate_pair_without_permission_operations(tmp_path: Path) -> None:
    source = tmp_path / "secrets"
    pmxcfs = tmp_path / "pve"
    source.mkdir()
    pmxcfs.mkdir()
    certificate_source = source / "certificate"
    key_source = source / "key"
    certificate_destination = pmxcfs / "pveproxy-ssl.pem"
    key_destination = pmxcfs / "pveproxy-ssl.key"
    certificate_source.write_text("new certificate")
    key_source.write_text("new key")
    certificate_destination.write_text("old certificate")
    key_destination.write_text("old key")
    stderr = io.StringIO()

    status = run(
        [
            "--certificate-source",
            str(certificate_source),
            "--certificate-destination",
            str(certificate_destination),
            "--key-source",
            str(key_source),
            "--key-destination",
            str(key_destination),
        ],
        stderr,
    )

    assert status == 0
    assert stderr.getvalue() == ""
    assert certificate_destination.read_text() == "new certificate"
    assert key_destination.read_text() == "new key"
    assert sorted(path.name for path in pmxcfs.iterdir()) == [
        "pveproxy-ssl.key",
        "pveproxy-ssl.pem",
    ]


def test_times_out_cleanly_when_pmxcfs_is_unavailable(tmp_path: Path) -> None:
    destination = tmp_path / "missing" / "certificate"
    stderr = io.StringIO()
    pmxcfs = Pmxcfs(attempts=2, interval_seconds=0, sleep=lambda _: None)

    with pytest.raises(Error, match="timed out"):
        pmxcfs.wait_writable(destination, stderr)

    assert "waiting for writable" in stderr.getvalue()
    assert not destination.parent.exists()


def test_copy_failure_preserves_existing_destination(tmp_path: Path) -> None:
    destination = tmp_path / "certificate"
    destination.write_text("preserved")

    with pytest.raises(Error, match="failed to install"):
        Pmxcfs().copy(tmp_path / "missing-source", destination, io.StringIO())

    assert destination.read_text() == "preserved"
    assert sorted(path.name for path in tmp_path.iterdir()) == ["certificate"]


@pytest.mark.parametrize("value", ["0", "-1"])
def test_attempt_count_must_be_positive(value: str) -> None:
    with pytest.raises(argparse.ArgumentTypeError):
        positive_integer(value)
