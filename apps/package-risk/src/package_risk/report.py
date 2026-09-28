from __future__ import annotations

import re
from collections.abc import Iterable

from .models import MetadataRecord, RiskReport, VersionInfo, Vulnerability

OSC8 = re.compile(r"\x1b]8;;[^\x1b]*\x1b\\")
CVE = re.compile(r"CVE-\d{4}-\d+", re.IGNORECASE)
GHSA = re.compile(r"GHSA-[0-9a-z-]+", re.IGNORECASE)


def _short(value: str, width: int = 48) -> str:
    return value if len(value) <= width else f"{value[: width - 1]}…"


def _visible_length(value: str) -> int:
    return len(OSC8.sub("", value))


def _pad(value: str, width: int) -> str:
    return value + " " * (width - _visible_length(value))


def _table(headers: tuple[str, ...], rows: Iterable[tuple[str, ...]]) -> str:
    materialized = list(rows)
    widths = [len(header) for header in headers]
    for row in materialized:
        widths = [
            max(current, _visible_length(value)) for current, value in zip(widths, row, strict=True)
        ]
    lines = ["  ".join(_pad(header, width) for header, width in zip(headers, widths, strict=True))]
    lines.append("  ".join("-" * width for width in widths))
    lines.extend(
        "  ".join(_pad(value, width) for value, width in zip(row, widths, strict=True)).rstrip()
        for row in materialized
    )
    return "\n".join(lines)


def _versions(comparisons: tuple[VersionInfo, ...]) -> str:
    values = []
    for item in comparisons:
        marker = "*" if item.knownVulnerabilities else ""
        values.append(f"{item.label}={item.version or '?'}{marker}")
    return ", ".join(values) or "-"


def _hyperlink(label: str, url: str, *, enabled: bool) -> str:
    if not enabled:
        return label
    return f"\x1b]8;;{url}\x1b\\{label}\x1b]8;;\x1b\\"


def _advisory(identifier: str, *, hyperlinks: bool) -> str:
    if CVE.fullmatch(identifier):
        url = f"https://nvd.nist.gov/vuln/detail/{identifier.upper()}"
    elif GHSA.fullmatch(identifier):
        url = f"https://github.com/advisories/{identifier.upper()}"
    else:
        return identifier
    return _hyperlink(identifier, url, enabled=hyperlinks)


def _advisory_lines(
    identifiers: tuple[str, ...], *, hyperlinks: bool, width: int = 48
) -> list[str]:
    lines: list[list[str]] = []
    current: list[str] = []
    current_width = 0
    for identifier in identifiers:
        added_width = len(identifier) + (2 if current else 0)
        if current and current_width + added_width > width:
            lines.append(current)
            current = []
            current_width = 0
        current.append(_advisory(identifier, hyperlinks=hyperlinks))
        current_width += len(identifier) + (2 if current_width else 0)
    if current:
        lines.append(current)
    return [", ".join(line) for line in lines] or ["-"]


def _vulnerability_rows(
    findings: tuple[Vulnerability, ...], *, hyperlinks: bool
) -> Iterable[tuple[str, ...]]:
    for finding in findings:
        for index, identifiers in enumerate(
            _advisory_lines(finding.identifiers, hyperlinks=hyperlinks)
        ):
            first = index == 0
            score = ""
            if first:
                score = f"{finding.score:.1f}" if finding.score is not None else "-"
            yield (
                score,
                finding.package if first else "",
                finding.version if first else "",
                _short(finding.attr_path, 32) if first else "",
                identifiers,
                _short(_versions(finding.comparisons), 96) if first else "",
                (
                    _hyperlink(
                        finding.source,
                        finding.reference_url,
                        enabled=hyperlinks,
                    )
                    if first and finding.reference_url
                    else finding.source
                    if first
                    else ""
                ),
            )


def _unmaintained_rows(packages: tuple[MetadataRecord, ...]) -> Iterable[tuple[str, ...]]:
    for package in sorted(packages, key=lambda item: (item.pname.lower(), item.version)):
        yield (
            package.pname,
            package.version,
            ".".join(package.attrPath),
            _short(package.meta.position),
        )


def render(report: RiskReport, *, hyperlinks: bool = False) -> str:
    lines = [
        f"Package risk: {report.configuration.name} ({report.configuration.system})",
        (
            f"Runtime closure: {report.closure_paths} paths; "
            f"{report.components} versioned path candidates; "
            f"{len(report.metadata)} exact package matches"
        ),
        "",
        f"Vulnerability findings ({len(report.vulnerabilities)})",
    ]
    if report.vulnerabilities:
        lines.append(
            _table(
                ("CVSS", "PACKAGE", "CURRENT", "ATTR", "CVE / ADVISORY", "OTHER INPUTS", "SOURCE"),
                _vulnerability_rows(report.vulnerabilities, hyperlinks=hyperlinks),
            )
        )
    else:
        lines.append("None found by the enabled sources.")
    lines.extend(("", f"Packages without maintainers or teams ({len(report.unmaintained)})"))
    if report.unmaintained:
        lines.append(
            _table(
                ("PACKAGE", "VERSION", "ATTR", "POSITION"), _unmaintained_rows(report.unmaintained)
            )
        )
    else:
        lines.append("None among exact metadata matches.")
    lines.extend(
        (
            "",
            "Notes:",
            (
                f"- The NixOS Security Tracker checked {report.tracker_checked_packages} "
                "package attributes selected by the local candidate index."
            ),
            (
                f"- {report.tracker_unclassified_matches} published tracker matches could not "
                "be classified for the installed version and are not listed as vulnerabilities."
            ),
        )
    )
    if report.tracker_closed_issue_matches:
        if report.tracker_closed_issue_matches == 1:
            lines.append(
                "- 1 affected tracker match was omitted because its nixpkgs issue is closed."
            )
        else:
            lines.append(
                f"- {report.tracker_closed_issue_matches} affected tracker matches were omitted "
                "because their nixpkgs issues are closed."
            )
    if report.tracker_unknown_issue_matches:
        if report.tracker_unknown_issue_matches == 1:
            lines.append(
                "- 1 affected tracker match was retained because its nixpkgs issue state is "
                "unknown."
            )
        else:
            lines.append(
                f"- {report.tracker_unknown_issue_matches} affected tracker matches were retained "
                "because their nixpkgs issue states are unknown."
            )
    lines.extend(
        (
            "- Published tracker matches are reported when affected and not known to be closed.",
            "- Nixpkgs metadata findings are declared by the evaluated package expression.",
            "- An asterisk after a comparison version marks known vulnerability metadata there.",
            (
                "- Maintainer results exclude derivations that could not be tied "
                "exactly to a package attribute."
            ),
        )
    )
    return "\n".join(lines)
