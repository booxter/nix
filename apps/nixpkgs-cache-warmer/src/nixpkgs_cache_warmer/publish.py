from __future__ import annotations

from pathlib import Path
from typing import TextIO

from nixpkgs_cache_warmer.commands import CommandError, CommandRunner


class AtticPublisher:
    def __init__(self, runner: CommandRunner, attic: Path) -> None:
        self._runner = runner
        self._attic = attic

    def publish(self, cache: str, outputs: tuple[Path, ...], log: TextIO) -> None:
        if not outputs:
            return
        print(f"Publishing {len(outputs)} output path(s) to Attic cache {cache}", file=log)
        result = self._runner.run(
            (str(self._attic), "push", cache, *(str(output) for output in outputs))
        )
        if result.stdout:
            log.write(result.stdout)
            if not result.stdout.endswith("\n"):
                log.write("\n")
        if result.stderr:
            log.write(result.stderr)
            if not result.stderr.endswith("\n"):
                log.write("\n")
        if result.returncode != 0:
            detail = result.stderr.strip() or f"exit status {result.returncode}"
            raise CommandError(f"Attic push to {cache} failed: {detail}")
        print(f"Published outputs to Attic cache {cache}", file=log)
