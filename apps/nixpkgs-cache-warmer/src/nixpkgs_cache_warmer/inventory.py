from __future__ import annotations

import json
from pathlib import Path

from pydantic import TypeAdapter, ValidationError

from nixpkgs_cache_warmer.commands import CommandError, CommandRunner, evaluate_json
from nixpkgs_cache_warmer.models import PackageTarget

TARGETS_ADAPTER = TypeAdapter(tuple[PackageTarget, ...])


class Inventory:
    def __init__(self, runner: CommandRunner, nix: Path, expression: Path) -> None:
        self._runner = runner
        self._nix = nix
        self._expression = expression

    def targets(
        self,
        source: Path,
        maintainer: str,
        system: str,
        exclude_pname_patterns: tuple[str, ...] = (),
    ) -> tuple[PackageTarget, ...]:
        raw = evaluate_json(
            self._runner,
            self._nix,
            self._expression,
            (
                ("nixpkgsSource", str(source.resolve())),
                ("maintainer", maintainer),
                ("system", system),
                ("excludePnamePatternsJson", json.dumps(exclude_pname_patterns)),
            ),
        )
        try:
            return TARGETS_ADAPTER.validate_json(raw)
        except ValidationError as error:
            raise CommandError(f"Nix returned an invalid package inventory: {error}") from error
