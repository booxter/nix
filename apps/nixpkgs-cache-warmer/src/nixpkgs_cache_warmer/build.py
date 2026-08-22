from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import TextIO

from nixpkgs_cache_warmer.commands import CommandRunner
from nixpkgs_cache_warmer.models import PackageTarget


@dataclass(frozen=True)
class BuildOutcome:
    successful: tuple[PackageTarget, ...]
    failed: tuple[PackageTarget, ...]
    outputs: tuple[Path, ...]


class NixBuilder:
    def __init__(self, runner: CommandRunner, nix: Path, log: TextIO) -> None:
        self._runner = runner
        self._nix = nix
        self._log = log

    def build(self, targets: tuple[PackageTarget, ...]) -> BuildOutcome:
        arguments = [
            str(self._nix),
            "build",
            "-L",
            "--keep-going",
            "--no-link",
            "--print-out-paths",
        ]
        arguments.extend(f"{target.drvPath}^*" for target in targets)
        result = self._runner.run_streaming(arguments, self._log)

        outputs = tuple(sorted({Path(line) for line in result.stdout.splitlines() if line.strip()}))
        output_set = set(outputs)
        successful = tuple(target for target in targets if set(target.outputs).issubset(output_set))
        successful_set = set(successful)
        failed = tuple(target for target in targets if target not in successful_set)
        return BuildOutcome(successful=successful, failed=failed, outputs=outputs)
