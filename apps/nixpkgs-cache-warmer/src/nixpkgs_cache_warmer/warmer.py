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


class Publisher(Protocol):
    def publish(self, cache: str, outputs: tuple[Path, ...], log: TextIO) -> None: ...


@dataclass(frozen=True)
class WarmOutcome:
    resolved: ResolvedSource
    build: BuildOutcome
    published_caches: tuple[str, ...]


class Warmer:
    def __init__(
        self,
        resolver: Resolver,
        inventory: PackageInventory,
        builder: PackageBuilder,
        publisher: Publisher | None = None,
    ) -> None:
        self._resolver = resolver
        self._inventory = inventory
        self._builder = builder
        self._publisher = publisher

    def warm(
        self,
        reference: str,
        maintainer: str,
        system: str,
        exclude_pname_patterns: tuple[str, ...],
        include_pname_patterns: tuple[str, ...],
        caches: tuple[str, ...],
        log: TextIO,
    ) -> WarmOutcome:
        resolved = self._resolver.resolve(reference)
        print(f"Resolved {reference} to {resolved.revision}", file=log)
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
        print(f"Building {len(targets)} package target(s) for {system}", file=log)
        build = self._builder.build(targets, log)
        print(
            f"Built {len(build.successful)}/{len(targets)} package target(s) "
            f"for {reference} at {resolved.revision}",
            file=log,
        )
        for target in build.failed:
            print(f"Failed: {target.pname} ({target.drvPath})", file=log)
        if caches and self._publisher is None:
            raise CommandError("Attic publication requested without a publisher")
        published_caches = []
        for cache in caches:
            assert self._publisher is not None
            self._publisher.publish(cache, build.outputs, log)
            published_caches.append(cache)
        if not caches:
            print("Attic publication disabled", file=log)
        return WarmOutcome(
            resolved=resolved,
            build=build,
            published_caches=tuple(published_caches),
        )
