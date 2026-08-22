from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Protocol, TextIO

from nixpkgs_cache_warmer.build import BuildOutcome
from nixpkgs_cache_warmer.commands import CommandError
from nixpkgs_cache_warmer.models import PackageTarget, ResolvedSource


class Resolver(Protocol):
    def resolve(self, reference: str) -> ResolvedSource: ...


class PackageInventory(Protocol):
    def instantiate(
        self,
        source: Path,
        maintainer: str,
        system: str,
        exclude_pname_patterns: tuple[str, ...] = (),
        include_pname_patterns: tuple[str, ...] = (),
    ) -> tuple[PackageTarget, ...]: ...


class PackageBuilder(Protocol):
    def build(self, targets: tuple[PackageTarget, ...], log: TextIO) -> BuildOutcome: ...


@dataclass(frozen=True)
class WarmOutcome:
    resolved: ResolvedSource
    build: BuildOutcome


@dataclass(frozen=True)
class PreparedTarget:
    resolved: ResolvedSource
    system: str
    packages: tuple[PackageTarget, ...]


class Warmer:
    def __init__(
        self,
        resolver: Resolver,
        inventory: PackageInventory,
        builder: PackageBuilder,
    ) -> None:
        self._resolver = resolver
        self._inventory = inventory
        self._builder = builder

    def warm(
        self,
        reference: str,
        maintainer: str,
        system: str,
        exclude_pname_patterns: tuple[str, ...],
        include_pname_patterns: tuple[str, ...],
        log: TextIO,
    ) -> WarmOutcome:
        prepared = self.prepare(
            reference,
            maintainer,
            system,
            exclude_pname_patterns,
            include_pname_patterns,
            log,
        )
        return self.build(prepared, log)

    def prepare(
        self,
        reference: str,
        maintainer: str,
        system: str,
        exclude_pname_patterns: tuple[str, ...],
        include_pname_patterns: tuple[str, ...],
        log: TextIO,
    ) -> PreparedTarget:
        print(f"Resolving {reference}", file=log)
        resolved = self._resolver.resolve(reference)
        print(f"Resolved {reference} to {resolved.revision}", file=log)
        print(f"Selecting packages maintained by {maintainer} for {system}", file=log)
        targets = self._inventory.instantiate(
            resolved.source,
            maintainer,
            system,
            exclude_pname_patterns,
            include_pname_patterns,
        )
        if not targets:
            raise CommandError(
                f"no maintained package targets selected for {reference} on {system}"
            )
        return PreparedTarget(resolved=resolved, system=system, packages=targets)

    def build(self, prepared: PreparedTarget, log: TextIO) -> WarmOutcome:
        print(
            f"Building {len(prepared.packages)} package target(s) for {prepared.system}",
            file=log,
        )
        build = self._builder.build(prepared.packages, log)
        print(
            f"Built {len(build.successful)}/{len(prepared.packages)} package target(s) "
            f"for {prepared.resolved.reference} at {prepared.resolved.revision}",
            file=log,
        )
        for target in build.failed:
            print(f"Failed: {target.pname} ({target.drvPath})", file=log)
        return WarmOutcome(resolved=prepared.resolved, build=build)
