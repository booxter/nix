import shutil
from pathlib import Path

import pytest
from memory_reclaim_metrics import collect, main, read_memory


class Source:
    def __init__(self, files: dict[str, str]):
        self.files = files

    def read(self, path: Path) -> str:
        try:
            return self.files[str(path)]
        except KeyError:
            raise FileNotFoundError(path) from None


def files() -> dict[str, str]:
    return {
        "vm/memory.current": "10000",
        "vm/memory.stat": (
            "anon 2000\nactive_anon 8000\ninactive_anon 1000\nshmem 500\nswapcached 100\n"
        ),
        "vm/memory.pressure": "some avg10=0 total=1500000\nfull avg10=0 total=250000\n",
        "vm/io.pressure": "some avg10=0 total=3000000\nfull avg10=0 total=0\n",
    }


def test_retained_memory_and_pressure() -> None:
    source = Source(files())
    assert read_memory(source, Path("vm")).unmapped == 6400
    output = collect(source, Path(), ["vm", "stopped"])
    assert 'memory_reclaim_cgroup_up{cgroup="stopped"} 0.0' in output
    assert 'memory_reclaim_bytes{cgroup="vm",kind="unmapped_anon"} 6400.0' in output
    assert 'kind="some",resource="memory"} 1.5' in output


def test_accounting_race_is_clamped() -> None:
    data = files()
    data["vm/memory.stat"] = "anon 10000\nactive_anon 8000\ninactive_anon 0\nshmem 0\n"
    assert read_memory(Source(data), Path("vm")).unmapped == 0


def test_invalid_data_fails_instead_of_reporting_zero() -> None:
    data = files()
    data["vm/memory.current"] = "invalid"
    with pytest.raises(ValueError):
        collect(Source(data), Path(), ["vm"])


def test_atomic_export_replaces_stopped_vm_sample(tmp_path: Path) -> None:
    for name, text in files().items():
        path = tmp_path / name
        path.parent.mkdir(exist_ok=True)
        path.write_text(text)
    output = tmp_path / "memory.prom"
    args = ["--cgroup-root", str(tmp_path), "--cgroup", "vm", "--output-file", str(output)]
    main(args)
    assert 'kind="unmapped_anon"' in output.read_text()
    (tmp_path / "vm/memory.current").unlink()
    main(args)
    assert 'kind="unmapped_anon"' not in output.read_text()


def test_wildcard_targets_follow_running_vms(tmp_path: Path) -> None:
    output = tmp_path / "memory.prom"
    args = [
        "--cgroup-root",
        str(tmp_path),
        "--cgroup",
        "qemu.slice/*.scope",
        "--output-file",
        str(output),
    ]
    main(args)
    assert 'cgroup="' not in output.read_text()

    for group in ("qemu.slice/100.scope", "qemu.slice/101.scope", "other.slice/102.scope"):
        for name, text in files().items():
            path = tmp_path / group / Path(name).name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
    (tmp_path / "qemu.slice/not-a-directory.scope").touch()
    main(args)
    assert 'cgroup="qemu.slice/100.scope"' in output.read_text()
    assert 'cgroup="qemu.slice/101.scope"' in output.read_text()
    assert "other.slice" not in output.read_text()
    assert "not-a-directory" not in output.read_text()

    shutil.rmtree(tmp_path / "qemu.slice/100.scope")
    main(args)
    assert 'cgroup="qemu.slice/100.scope"' not in output.read_text()
    assert 'cgroup="qemu.slice/101.scope"' in output.read_text()
