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
        reference: str,
        maintainer: str,
        system: str,
        exclude_pname_patterns: tuple[str, ...] = (),
        include_pname_patterns: tuple[str, ...] = (),
    ) -> tuple[PackageTarget, ...]: ...


class PackageBuilder(Protocol):
    def build(self, targets: tuple[PackageTarget, ...]) -> BuildOutcome: ...


@dataclass(frozen=True)
class WarmOutcome:
    resolved: ResolvedSource
    build: BuildOutcome


@dataclass(frozen=True)
class PreparedTarget:
    resolved: ResolvedSource
    system: str
    packages: tuple[PackageTarget, ...]


@dataclass(frozen=True)
class PreparationFailure:
    reference: str
    system: str
    error: str


@dataclass(frozen=True)
class PreparationOutcome:
    prepared: tuple[PreparedTarget, ...]
    failed: tuple[PreparationFailure, ...]


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
        resolved = self.resolve(reference, log)
        return self.prepare_resolved(
            resolved,
            maintainer,
            system,
            exclude_pname_patterns,
            include_pname_patterns,
            log,
        )

    def resolve(self, reference: str, log: TextIO) -> ResolvedSource:
        print(f"Resolving {reference}", file=log)
        resolved = self._resolver.resolve(reference)
        print(f"Resolved {reference} to {resolved.revision}", file=log)
        return resolved

    def prepare_resolved(
        self,
        resolved: ResolvedSource,
        maintainer: str,
        system: str,
        exclude_pname_patterns: tuple[str, ...],
        include_pname_patterns: tuple[str, ...],
        log: TextIO,
    ) -> PreparedTarget:
        print(f"Selecting packages maintained by {maintainer} for {system}", file=log)
        targets = self._inventory.instantiate(
            resolved.source,
            resolved.reference,
            maintainer,
            system,
            exclude_pname_patterns,
            include_pname_patterns,
        )
        if not targets:
            raise CommandError(
                f"no maintained package targets selected for {resolved.reference} on {system}"
            )
        return PreparedTarget(resolved=resolved, system=system, packages=targets)

    def prepare_matrix(
        self,
        references: tuple[str, ...],
        maintainer: str,
        systems: tuple[str, ...],
        exclude_pname_patterns: tuple[str, ...],
        include_pname_patterns: tuple[str, ...],
        log: TextIO,
    ) -> PreparationOutcome:
        prepared: list[PreparedTarget] = []
        failed: list[PreparationFailure] = []
        for reference in references:
            try:
                resolved = self.resolve(reference, log)
            except CommandError as error:
                failed.extend(
                    PreparationFailure(reference, system, str(error)) for system in systems
                )
                continue
            for system in systems:
                try:
                    prepared.append(
                        self.prepare_resolved(
                            resolved,
                            maintainer,
                            system,
                            exclude_pname_patterns,
                            include_pname_patterns,
                            log,
                        )
                    )
                except CommandError as error:
                    failed.append(PreparationFailure(reference, system, str(error)))
        return PreparationOutcome(prepared=tuple(prepared), failed=tuple(failed))

    def build(self, prepared: PreparedTarget, log: TextIO) -> WarmOutcome:
        print(
            f"Building {len(prepared.packages)} package target(s) for {prepared.system}",
            file=log,
        )
        build = self._builder.build(prepared.packages)
        print(
            f"Built {len(build.successful)}/{len(prepared.packages)} package target(s) "
            f"for {prepared.resolved.reference} at {prepared.resolved.revision}",
            file=log,
        )
        for target in build.failed:
            print(f"Failed: {target.pname} ({target.drvPath})", file=log)
        return WarmOutcome(resolved=prepared.resolved, build=build)

    def build_matrix(
        self, prepared_targets: tuple[PreparedTarget, ...], log: TextIO
    ) -> tuple[WarmOutcome, ...]:
        packages_by_drv_path: dict[Path, PackageTarget] = {}
        for prepared in prepared_targets:
            for package in prepared.packages:
                packages_by_drv_path.setdefault(package.drvPath, package)
        packages = tuple(packages_by_drv_path.values())
        if not packages:
            return ()
        print(
            f"Building {len(packages)} unique package target(s) "
            f"across {len(prepared_targets)} matrix target(s)",
            file=log,
        )
        combined = self._builder.build(packages)
        successful_drv_paths = {package.drvPath for package in combined.successful}
        outcomes = []
        for prepared in prepared_targets:
            successful = tuple(
                package for package in prepared.packages if package.drvPath in successful_drv_paths
            )
            failed = tuple(
                package
                for package in prepared.packages
                if package.drvPath not in successful_drv_paths
            )
            outputs = tuple(
                sorted({output for package in successful for output in package.outputs})
            )
            build = BuildOutcome(successful=successful, failed=failed, outputs=outputs)
            print(
                f"Built {len(successful)}/{len(prepared.packages)} package target(s) "
                f"for {prepared.resolved.reference} on {prepared.system} "
                f"at {prepared.resolved.revision}",
                file=log,
            )
            for package in failed:
                print(
                    f"Failed for {prepared.resolved.reference} on {prepared.system}: "
                    f"{package.pname} ({package.drvPath})",
                    file=log,
                )
            outcomes.append(WarmOutcome(resolved=prepared.resolved, build=build))
        return tuple(outcomes)
