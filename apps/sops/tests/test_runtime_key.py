from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from sops_tools.runtime_key import AgeKeyGenerator, ensure_runtime_key


@dataclass
class FakeAgeKeyGenerator(AgeKeyGenerator):
    calls: int = 0

    def generate(self, path: Path) -> None:
        self.calls += 1
        path.write_text("# public key: age1runtime\nAGE-SECRET-KEY-1TEST\n")


def test_runtime_key_is_created_privately_and_reused(tmp_path: Path) -> None:
    path = tmp_path / "sops/key.txt"
    generator = FakeAgeKeyGenerator()

    assert ensure_runtime_key(path, generator) == "age1runtime"
    assert ensure_runtime_key(path, generator) == "age1runtime"

    assert generator.calls == 1
    assert path.stat().st_mode & 0o777 == 0o400
