from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from pydantic import BaseModel, ConfigDict, Field


class Configuration(BaseModel):
    model_config = ConfigDict(extra="forbid")

    kind: str
    name: str
    system: str


class PathInfo(BaseModel):
    model_config = ConfigDict(extra="ignore")

    deriver: str | None = None


class DerivationRecord(BaseModel):
    model_config = ConfigDict(extra="ignore")

    env: dict[str, str] = Field(default_factory=dict)


class VersionInfo(BaseModel):
    model_config = ConfigDict(extra="forbid")

    label: str
    version: str
    knownVulnerabilities: list[str]


class PackageMeta(BaseModel):
    model_config = ConfigDict(extra="forbid")

    maintainers: list[str]
    teams: list[str]
    knownVulnerabilities: list[str]
    position: str


class MetadataRecord(BaseModel):
    model_config = ConfigDict(extra="forbid")

    drvPath: str
    name: str
    pname: str
    version: str
    attrPath: list[str]
    meta: PackageMeta
    comparisons: list[VersionInfo]


class MetadataResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    components: list[MetadataRecord]


class VulnixRecord(BaseModel):
    model_config = ConfigDict(extra="ignore")

    name: str
    pname: str
    version: str
    derivation: str | None
    affected_by: list[str]
    cvssv3_basescore: dict[str, float]
    description: dict[str, str] = Field(default_factory=dict)


class TrackerAffectedProduct(BaseModel):
    model_config = ConfigDict(extra="ignore")

    version_constraints: list[tuple[str, str | None]]


class TrackerMetric(BaseModel):
    model_config = ConfigDict(extra="ignore")

    base_score: float | None = None


class TrackerSuggestion(BaseModel):
    model_config = ConfigDict(extra="ignore")

    id: int
    status: str
    issue_code: str | None = None
    cve_id: str
    affected_products: list[TrackerAffectedProduct]
    packages: dict[str, object]
    metrics: list[TrackerMetric]


class TrackerPage(BaseModel):
    model_config = ConfigDict(extra="ignore")

    next: str | None
    results: list[TrackerSuggestion]


class ComponentRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    drvPath: str
    outputPath: str
    name: str
    pname: str
    version: str
    candidatePaths: list[list[str]]


class ExternalComparison(BaseModel):
    model_config = ConfigDict(extra="forbid")

    label: str
    flakeRef: str


class MetadataRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    flakeRef: str
    kind: str
    config: str
    system: str
    comparisonInputs: list[str]
    externalComparisons: list[ExternalComparison]
    components: list[ComponentRequest]


@dataclass(frozen=True)
class Component:
    drv_path: str
    output_path: str
    name: str
    pname: str
    version: str


@dataclass(frozen=True)
class Vulnerability:
    package: str
    version: str
    attr_path: str
    identifiers: tuple[str, ...]
    score: float | None
    source: str
    reference_url: str | None
    comparisons: tuple[VersionInfo, ...]


@dataclass(frozen=True)
class TrackerFinding:
    attr_path: str
    identifier: str
    score: float | None
    reference_url: str


@dataclass(frozen=True)
class TrackerScan:
    findings: tuple[TrackerFinding, ...]
    checked_packages: int
    unclassified_matches: int
    closed_issue_matches: int = 0
    unknown_issue_matches: int = 0


@dataclass(frozen=True)
class RiskReport:
    configuration: Configuration
    closure_paths: int
    components: int
    metadata: tuple[MetadataRecord, ...]
    vulnerabilities: tuple[Vulnerability, ...]
    tracker_checked_packages: int = 0
    tracker_unclassified_matches: int = 0
    tracker_closed_issue_matches: int = 0
    tracker_unknown_issue_matches: int = 0

    @property
    def unmaintained(self) -> tuple[MetadataRecord, ...]:
        return tuple(
            package
            for package in self.metadata
            if not package.meta.maintainers and not package.meta.teams
        )


def json_object(value: Any) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ValueError("expected a JSON object")
    return value
