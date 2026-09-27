from __future__ import annotations

from package_risk.audit import Auditor, make_report
from package_risk.models import (
    Component,
    Configuration,
    MetadataRecord,
    MetadataResponse,
    PackageMeta,
    TrackerFinding,
    TrackerScan,
    VersionInfo,
    VulnixRecord,
)
from package_risk.report import render


def package(*, maintained: bool = True, vulnerable: bool = False) -> MetadataRecord:
    return MetadataRecord(
        drvPath="/nix/store/openssl.drv",
        name="openssl-1",
        pname="openssl",
        version="1",
        attrPath=["openssl"],
        meta=PackageMeta(
            maintainers=["alice"] if maintained else [],
            teams=[],
            knownVulnerabilities=["GHSA-1111-2222-3333"] if vulnerable else [],
            position="pkgs/openssl.nix:1",
        ),
        comparisons=[
            VersionInfo(
                label="nixpkgs-unstable",
                version="2",
                knownVulnerabilities=["CVE-OTHER"],
            )
        ],
    )


def test_make_report_combines_vulnerability_sources() -> None:
    configuration = Configuration(kind="nixos", name="host", system="x86_64-linux")
    component = Component(
        "/nix/store/openssl.drv", "/nix/store/openssl-1", "openssl-1", "openssl", "1"
    )
    report = make_report(
        configuration,
        20,
        [component],
        [package(maintained=False, vulnerable=True)],
        TrackerScan(
            findings=(
                TrackerFinding(
                    attr_path="openssl",
                    identifier="CVE-2026-1234",
                    score=9.8,
                    reference_url="https://github.com/NixOS/nixpkgs/issues/1234",
                ),
            ),
            checked_packages=1,
            unclassified_matches=2,
            closed_issue_matches=3,
            unknown_issue_matches=1,
        ),
    )
    assert report.closure_paths == 20
    assert [finding.source for finding in report.vulnerabilities] == [
        "NixOS tracker",
        "Nixpkgs metadata",
    ]
    assert report.vulnerabilities[0].score == 9.8
    assert report.vulnerabilities[0].attr_path == "openssl"
    assert report.unmaintained == (report.metadata[0],)
    output = render(report)
    assert "CVE-2026-1234" in output
    assert "nixpkgs-unstable=2*" in output
    assert "Packages without maintainers or teams (1)" in output
    assert "2 published tracker matches" in output
    assert "3 affected tracker matches were omitted" in output
    assert "1 affected tracker match was retained" in output
    assert report.tracker_closed_issue_matches == 3
    assert report.tracker_unknown_issue_matches == 1
    linked = render(report, hyperlinks=True)
    assert "\x1b]8;;https://nvd.nist.gov/vuln/detail/CVE-2026-1234\x1b\\" in linked
    assert "\x1b]8;;https://github.com/NixOS/nixpkgs/issues/1234\x1b\\" in linked
    assert "\x1b]8;;https://github.com/advisories/GHSA-1111-2222-3333\x1b\\" in linked


def test_make_report_deduplicates_metadata_with_tracker_precedence() -> None:
    report = make_report(
        Configuration(kind="darwin", name="mac", system="aarch64-darwin"),
        1,
        [
            Component(
                "/nix/store/openssl.drv",
                "/nix/store/openssl-1",
                "openssl-1",
                "openssl",
                "1",
            )
        ],
        [package(vulnerable=True)],
        TrackerScan(
            findings=(
                TrackerFinding(
                    attr_path="openssl",
                    identifier="GHSA-1111-2222-3333",
                    score=5.0,
                    reference_url="https://tracker.example/suggestion",
                ),
            ),
            checked_packages=1,
            unclassified_matches=0,
        ),
    )
    assert len(report.vulnerabilities) == 1
    assert report.vulnerabilities[0].source == "NixOS tracker"


def test_render_empty_report() -> None:
    report = make_report(
        Configuration(kind="nixos", name="clean", system="x86_64-linux"),
        0,
        [],
        [package()],
        TrackerScan(findings=(), checked_packages=0, unclassified_matches=0),
    )
    output = render(report)
    assert "None found by the enabled sources." in output
    assert "None among exact metadata matches." in output


class FakeNix:
    def target(self, flake: str, configuration: Configuration) -> str:
        return f"{flake}#{configuration.name}"

    def realize(self, target: str, *, build: bool) -> tuple[str, ...]:
        assert target == ".#host"
        assert build
        return ("/nix/store/system",)

    def closure(self, outputs: tuple[str, ...]) -> tuple[int, list[Component]]:
        assert outputs == ("/nix/store/system",)
        return 3, [
            Component(
                "/nix/store/openssl.drv",
                "/nix/store/openssl-1",
                "openssl-1",
                "openssl",
                "1",
            )
        ]

    def metadata(self, **_arguments: object) -> MetadataResponse:
        return MetadataResponse(components=[package()])

    def vulnerabilities(self, outputs: tuple[str, ...]) -> list[VulnixRecord]:
        assert outputs == ("/nix/store/system",)
        return []


class FakeTracker:
    def __init__(self) -> None:
        self.packages: list[MetadataRecord] | None = None

    def scan(self, packages: list[MetadataRecord]) -> TrackerScan:
        self.packages = packages
        return TrackerScan(findings=(), checked_packages=len(packages), unclassified_matches=0)


def test_auditor_orchestrates_scan() -> None:
    notes: list[str] = []
    tracker = FakeTracker()
    auditor = Auditor(FakeNix(), tracker, notes.append)  # type: ignore[arg-type]
    report = auditor.run(
        ".",
        Configuration(kind="nixos", name="host", system="x86_64-linux"),
        build=True,
        scan_tracker=True,
        comparison_inputs=[],
        external_comparisons=[],
    )
    assert report.components == 1
    assert len(notes) == 5
    assert tracker.packages == []


def test_auditor_can_skip_vulnerability_scan() -> None:
    class NoScanNix(FakeNix):
        def vulnerabilities(self, outputs: tuple[str, ...]) -> list[VulnixRecord]:
            raise AssertionError("should not scan")

    report = Auditor(NoScanNix(), FakeTracker(), lambda _message: None).run(  # type: ignore[arg-type]
        ".",
        Configuration(kind="nixos", name="host", system="x86_64-linux"),
        build=True,
        scan_tracker=False,
        comparison_inputs=[],
        external_comparisons=[],
    )
    assert not report.vulnerabilities
