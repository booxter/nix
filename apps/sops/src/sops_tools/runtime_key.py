from __future__ import annotations

import argparse
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol, Sequence


class RuntimeKeyError(RuntimeError):
    pass


class AgeKeyGenerator(Protocol):
    def generate(self, path: Path) -> None: ...


@dataclass(frozen=True)
class CommandAgeKeyGenerator:
    executable: Path

    def generate(self, path: Path) -> None:
        completed = subprocess.run([str(self.executable), "-o", str(path)], check=False)
        if completed.returncode != 0:
            raise RuntimeKeyError("Failed to generate the SOPS runtime age key.")


def ensure_runtime_key(path: Path, generator: AgeKeyGenerator) -> str:
    path.parent.mkdir(parents=True, exist_ok=True)
    if not path.is_file():
        generator.generate(path)
    path.chmod(0o400)
    recipients = [
        line.removeprefix("# public key: ").strip()
        for line in path.read_text().splitlines()
        if line.startswith("# public key: ")
    ]
    if not recipients or not recipients[-1]:
        raise RuntimeKeyError(f"Failed to parse age public key from {path}.")
    return recipients[-1]


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--age-keygen", required=True, type=Path)
    parser.add_argument("path", type=Path)
    args = parser.parse_args(argv)
    try:
        recipient = ensure_runtime_key(
            args.path, CommandAgeKeyGenerator(args.age_keygen)
        )
    except RuntimeKeyError as error:
        parser.exit(1, f"{error}\n")
    print(recipient)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
