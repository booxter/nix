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
        include_pname_patterns: tuple[str, ...] = (),
    ) -> tuple[PackageTarget, ...]:
        arguments = self._arguments(
            source,
            maintainer,
            system,
            exclude_pname_patterns,
            include_pname_patterns,
        )
        raw = evaluate_json(
            self._runner,
            self._nix,
            self._expression,
            arguments,
        )
        try:
            return TARGETS_ADAPTER.validate_json(raw)
        except ValidationError as error:
            raise CommandError(f"Nix returned an invalid package inventory: {error}") from error

    def instantiate(
        self,
        source: Path,
        maintainer: str,
        system: str,
        exclude_pname_patterns: tuple[str, ...] = (),
        include_pname_patterns: tuple[str, ...] = (),
    ) -> tuple[PackageTarget, ...]:
        targets = self.targets(
            source,
            maintainer,
            system,
            exclude_pname_patterns,
            include_pname_patterns,
        )
        arguments = [str(self._nix), str(self._expression)]
        for name, value in self._arguments(
            source,
            maintainer,
            system,
            exclude_pname_patterns,
            include_pname_patterns,
        ) + (("output", "packages"),):
            arguments.extend(("--argstr", name, value))
        result = self._runner.run(arguments)
        if result.returncode != 0:
            detail = result.stderr.strip() or f"exit status {result.returncode}"
            raise CommandError(f"failed to instantiate package inventory: {detail}")
        instantiated = {Path(line) for line in result.stdout.splitlines() if line.strip()}
        expected = {target.drvPath for target in targets}
        if instantiated != expected:
            raise CommandError(
                "instantiated derivations do not match the evaluated package inventory"
            )
        return targets

    @staticmethod
    def _arguments(
        source: Path,
        maintainer: str,
        system: str,
        exclude_pname_patterns: tuple[str, ...],
        include_pname_patterns: tuple[str, ...],
    ) -> tuple[tuple[str, str], ...]:
        return (
            ("nixpkgsSource", str(source.resolve())),
            ("maintainer", maintainer),
            ("system", system),
            ("excludePnamePatternsJson", json.dumps(exclude_pname_patterns)),
            ("includePnamePatternsJson", json.dumps(include_pname_patterns)),
        )
