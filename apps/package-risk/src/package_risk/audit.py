from __future__ import annotations

from collections.abc import Callable
from typing import Protocol

from .models import (
    Component,
    Configuration,
    ExternalComparison,
    MetadataRecord,
    RiskReport,
    TrackerScan,
    VersionInfo,
    Vulnerability,
)
from .nix import NixClient


class SecurityTracker(Protocol):
    def scan(self, packages: list[MetadataRecord]) -> TrackerScan: ...


class Auditor:
    def __init__(
        self, nix: NixClient, tracker: SecurityTracker, note: Callable[[str], None]
    ) -> None:
        self.nix = nix
        self.tracker = tracker
        self.note = note

    def run(
        self,
        flake: str,
        configuration: Configuration,
        *,
        build: bool,
        scan_tracker: bool,
        comparison_inputs: list[str],
        external_comparisons: list[ExternalComparison],
    ) -> RiskReport:
        target = self.nix.target(flake, configuration)
        self.note(f"{configuration.name}: {'realizing' if build else 'checking'} runtime closure")
        outputs = self.nix.realize(target, build=build)
        self.note(f"{configuration.name}: reading runtime dependencies")
        closure_paths, components = self.nix.closure(outputs)
        self.note(
            f"{configuration.name}: matching {len(components)} package derivations to metadata"
        )
        raw_metadata = self.nix.metadata(
            flake=flake,
            configuration=configuration,
            components=components,
            comparison_inputs=comparison_inputs,
            external_comparisons=external_comparisons,
        ).components
        metadata = list({package.drvPath: package for package in raw_metadata}.values())
        tracker = TrackerScan(findings=(), checked_packages=0, unclassified_matches=0)
        if scan_tracker:
            self.note(f"{configuration.name}: finding packages to check with the security tracker")
            candidates = self.nix.vulnerabilities(outputs)
            candidate_derivations = {
                finding.derivation for finding in candidates if finding.derivation is not None
            }
            candidate_packages = {(finding.pname, finding.version) for finding in candidates}
            tracker_packages = [
                package
                for package in metadata
                if package.drvPath in candidate_derivations
                or (package.pname, package.version) in candidate_packages
                or package.meta.knownVulnerabilities
            ]
            self.note(
                f"{configuration.name}: checking {len(tracker_packages)} package attributes "
                "against published tracker records"
            )
            tracker = self.tracker.scan(tracker_packages)
        return make_report(configuration, closure_paths, components, metadata, tracker)


def _comparison_tuple(package: MetadataRecord) -> tuple[VersionInfo, ...]:
    return tuple(package.comparisons)


def _deduplicate(findings: list[Vulnerability]) -> list[Vulnerability]:
    unique: dict[tuple[str, str, tuple[str, ...]], Vulnerability] = {}
    for finding in findings:
        key = (
            finding.package,
            finding.version,
            tuple(sorted(finding.identifiers)),
        )
        current = unique.get(key)
        if current is None or (
            current.source == "Nixpkgs metadata" and finding.source == "NixOS tracker"
        ):
            unique[key] = finding
    return list(unique.values())


def make_report(
    configuration: Configuration,
    closure_paths: int,
    components: list[Component],
    metadata: list[MetadataRecord],
    tracker: TrackerScan,
) -> RiskReport:
    by_attr = {".".join(package.attrPath): package for package in metadata}
    vulnerabilities: list[Vulnerability] = []
    for finding in tracker.findings:
        package = by_attr[finding.attr_path]
        vulnerabilities.append(
            Vulnerability(
                package=package.pname,
                version=package.version,
                attr_path=finding.attr_path,
                identifiers=(finding.identifier,),
                score=finding.score,
                source="NixOS tracker",
                reference_url=finding.reference_url,
                comparisons=_comparison_tuple(package),
            )
        )
    for package in metadata:
        vulnerabilities.extend(
            Vulnerability(
                package=package.pname,
                version=package.version,
                attr_path=".".join(package.attrPath),
                identifiers=(identifier,),
                score=None,
                source="Nixpkgs metadata",
                reference_url=None,
                comparisons=tuple(package.comparisons),
            )
            for identifier in package.meta.knownVulnerabilities
        )
    vulnerabilities = _deduplicate(vulnerabilities)
    return RiskReport(
        configuration=configuration,
        closure_paths=closure_paths,
        components=len(components),
        metadata=tuple(metadata),
        tracker_checked_packages=tracker.checked_packages,
        tracker_unclassified_matches=tracker.unclassified_matches,
        tracker_closed_issue_matches=tracker.closed_issue_matches,
        tracker_unknown_issue_matches=tracker.unknown_issue_matches,
        vulnerabilities=tuple(
            sorted(
                vulnerabilities,
                key=lambda finding: (
                    -(finding.score if finding.score is not None else -1),
                    finding.package.lower(),
                    finding.version,
                ),
            )
        ),
    )
