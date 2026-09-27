from __future__ import annotations

import json
import re
import time
from collections.abc import Callable, Iterable, Mapping
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any, Protocol
from urllib.parse import urlencode, urljoin, urlparse

import httpx
from github import Github
from github.GithubException import GithubException
from pydantic import BaseModel, ConfigDict, Field, ValidationError
from requests import RequestException
from univers.versions import DebianVersion, InvalidVersion

from .models import MetadataRecord, TrackerFinding, TrackerPage, TrackerScan, TrackerSuggestion
from .process import RiskError

TRACKER_URL = "https://tracker.security.nixos.org/"
CACHE_SCHEMA = 1
TRACKER_ISSUE = re.compile(r"https?://tracker\.security\.nixos\.org/+issues/(NIXPKGS-\d{4}-\d+)")


class JsonTransport(Protocol):
    def get(self, url: str) -> Mapping[str, Any]: ...


class HttpTransport:
    def __init__(
        self,
        *,
        token: str | None,
        note: Callable[[str], None],
        sleeper: Callable[[float], None] = time.sleep,
        client: httpx.Client | None = None,
    ) -> None:
        headers = {"Accept": "application/json", "User-Agent": "package-risk/0.1"}
        if token:
            headers["Authorization"] = f"Bearer {token}"
        self.client = client or httpx.Client(headers=headers, timeout=60, follow_redirects=True)
        self.note = note
        self.sleeper = sleeper

    def get(self, url: str) -> Mapping[str, Any]:
        for attempt in range(4):
            try:
                response = self.client.get(url)
            except httpx.HTTPError as error:
                raise RiskError(f"NixOS Security Tracker request failed: {error}") from error
            if response.status_code != 429:
                try:
                    response.raise_for_status()
                    value = response.json()
                except (httpx.HTTPError, json.JSONDecodeError) as error:
                    raise RiskError(f"NixOS Security Tracker request failed: {error}") from error
                if not isinstance(value, dict):
                    raise RiskError("NixOS Security Tracker returned a non-object response")
                return value
            if attempt == 3:
                break
            retry_after = response.headers.get("Retry-After", "60")
            try:
                delay = max(float(retry_after), 1.0)
            except ValueError:
                delay = 60.0
            self.note(f"NixOS Security Tracker rate limit reached; retrying in {delay:g}s")
            self.sleeper(delay)
        raise RiskError("NixOS Security Tracker rate limit persisted after retries")

    def close(self) -> None:
        self.client.close()


class OpenIssueResolver(Protocol):
    def find_open(self) -> Mapping[str, str]: ...


class GitHubIssueResolver:
    def __init__(self, client: Github) -> None:
        self.client = client

    def find_open(self) -> Mapping[str, str]:
        query = 'repo:NixOS/nixpkgs is:issue is:open "Nixpkgs security tracker issue" in:body'
        try:
            issues = self.client.search_issues(query=query)
            if issues.totalCount > 1_000:
                raise RiskError("GitHub issue search exceeds its 1,000-result limit")

            result: dict[str, str] = {}
            issue_ids: set[int] = set()
            for issue in issues:
                match = TRACKER_ISSUE.search(issue.body or "")
                if match is None:
                    raise RiskError("GitHub issue search returned an issue without a tracker code")
                issue_ids.add(issue.id)
                result[match.group(1)] = issue.html_url
            if len(issue_ids) != issues.totalCount:
                raise RiskError("GitHub issue search changed while it was being read")
            return result
        except (GithubException, RequestException) as error:
            raise RiskError(f"GitHub issue lookup failed: {error}") from error


class CachedSuggestion(BaseModel):
    model_config = ConfigDict(extra="forbid")

    cve_id: str
    score: float | None
    constraints: list[tuple[str, str | None]]
    reference_url: str
    issue_code: str | None = None


class PackageCacheEntry(BaseModel):
    model_config = ConfigDict(extra="forbid")

    fetched_at: datetime
    suggestions: list[CachedSuggestion]


class OpenIssuesCacheEntry(BaseModel):
    model_config = ConfigDict(extra="forbid")

    fetched_at: datetime
    issue_urls: dict[str, str]


class TrackerCacheDocument(BaseModel):
    model_config = ConfigDict(extra="forbid")

    schema_version: int = CACHE_SCHEMA
    packages: dict[str, PackageCacheEntry] = Field(default_factory=dict)
    open_issues: OpenIssuesCacheEntry | None = None


class TrackerCache:
    def __init__(self, path: Path) -> None:
        self.path = path

    def load(self) -> TrackerCacheDocument:
        try:
            return TrackerCacheDocument.model_validate_json(self.path.read_text())
        except FileNotFoundError:
            return TrackerCacheDocument()
        except (OSError, ValidationError) as error:
            raise RiskError(f"could not read tracker cache {self.path}: {error}") from error

    def save(self, document: TrackerCacheDocument) -> None:
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            temporary = self.path.with_suffix(f"{self.path.suffix}.tmp")
            temporary.write_text(document.model_dump_json())
            temporary.replace(self.path)
        except OSError as error:
            raise RiskError(f"could not write tracker cache {self.path}: {error}") from error


def _clean_version(value: str) -> DebianVersion | None:
    cleaned = re.sub(r"^v", "", value)
    cleaned = re.sub(r"-?unstable-.*$", "", cleaned)
    cleaned = cleaned.replace("_", ".")
    cleaned = re.sub(r"[-._]?(pre|rc|alpha|beta|dev)(?=[0-9.]|$)", r"~\1", cleaned)
    try:
        return DebianVersion(cleaned)
    except InvalidVersion:
        return None


def _relations(expression: str) -> list[tuple[str, str]] | None:
    value = expression.strip()
    if value == "*":
        return []
    if value.startswith("=<"):
        value = f"<={value[2:]}"
    elif value.startswith("=="):
        value = value[2:].strip()
        if not value.startswith(("<", ">", "=")):
            value = f"={value}"
    relations: list[tuple[str, str]] = []
    for item in value.split(","):
        match = re.fullmatch(r"\s*(<=|>=|<|>|=|==)?\s*(\S(?:.*\S)?)\s*", item)
        if not match:
            return None
        relations.append((match.group(1) or "=", match.group(2)))
    return relations


def constraint_matches(version: str, expression: str | None) -> bool | None:
    if expression is None:
        return None
    relations = _relations(expression)
    if relations is None:
        return None
    if not relations:
        return True
    parsed_version = _clean_version(version)
    if parsed_version is None:
        return None
    for operator, bound in relations:
        parsed_bound = _clean_version(bound)
        if parsed_bound is None:
            return None
        matches = {
            "<": parsed_version < parsed_bound,
            "<=": parsed_version <= parsed_bound,
            ">": parsed_version > parsed_bound,
            ">=": parsed_version >= parsed_bound,
            "=": parsed_version == parsed_bound,
            "==": parsed_version == parsed_bound,
        }[operator]
        if not matches:
            return False
    return True


def _affected(version: str, constraints: Iterable[tuple[str, str | None]]) -> bool | None:
    matches: list[str] = []
    unknown = False
    for status, expression in constraints:
        result = constraint_matches(version, expression)
        if result is True:
            matches.append(status)
        elif result is None:
            unknown = True
    if matches:
        rank = {"unaffected": 0, "unknown": 1, "affected": 2}
        return max(matches, key=lambda status: rank.get(status, 1)) == "affected"
    return None if unknown else False


def _cached_suggestion(suggestion: TrackerSuggestion, *, base_url: str) -> CachedSuggestion:
    scores = [metric.base_score for metric in suggestion.metrics if metric.base_score is not None]
    constraints = [
        constraint
        for product in suggestion.affected_products
        for constraint in product.version_constraints
    ]
    reference = urljoin(base_url, f"suggestions/by-cve/{suggestion.cve_id}/")
    return CachedSuggestion(
        cve_id=suggestion.cve_id,
        score=max(scores) if scores else None,
        constraints=constraints,
        reference_url=reference,
        issue_code=suggestion.issue_code,
    )


class TrackerClient:
    def __init__(
        self,
        transport: JsonTransport,
        cache: TrackerCache,
        *,
        note: Callable[[str], None],
        open_issues: OpenIssueResolver | None = None,
        base_url: str = TRACKER_URL,
        max_age: timedelta = timedelta(hours=24),
        now: Callable[[], datetime] = lambda: datetime.now(UTC),
    ) -> None:
        self.transport = transport
        self.cache = cache
        self.note = note
        self.open_issues = open_issues
        self.base_url = base_url.rstrip("/") + "/"
        self.max_age = max_age
        self.now = now

    def _url(self, attr_path: str, page: int | None = None) -> str:
        query: list[tuple[str, str]] = [("status", "published"), ("package", attr_path)]
        if page is not None:
            query.append(("page", str(page)))
        return urljoin(self.base_url, "api/v1/suggestions") + "?" + urlencode(query)

    def _fetch(self, attr_path: str) -> list[CachedSuggestion]:
        suggestions: dict[int, TrackerSuggestion] = {}
        page_number = 1
        while True:
            try:
                page = TrackerPage.model_validate(
                    self.transport.get(self._url(attr_path, page_number))
                )
            except ValidationError as error:
                raise RiskError(
                    f"could not parse NixOS Security Tracker response: {error}"
                ) from error
            for suggestion in page.results:
                if suggestion.status == "published" and attr_path in suggestion.packages:
                    suggestions[suggestion.id] = suggestion
            if page.next is None:
                break
            next_page = urlparse(page.next)
            if next_page.path != "/api/v1/suggestions":
                raise RiskError("NixOS Security Tracker returned an unexpected pagination URL")
            page_number += 1
        return [
            _cached_suggestion(suggestion, base_url=self.base_url)
            for suggestion in suggestions.values()
        ]

    def scan(self, packages: Iterable[MetadataRecord]) -> TrackerScan:
        document = self.cache.load()
        now = self.now()
        affected_matches: list[tuple[str, CachedSuggestion, datetime]] = []
        unclassified = 0
        materialized = sorted(packages, key=lambda package: package.attrPath)
        for index, package in enumerate(materialized, start=1):
            attr_path = ".".join(package.attrPath)
            entry = document.packages.get(attr_path)
            if (
                entry is None
                or now - entry.fetched_at > self.max_age
                or any(suggestion.issue_code is None for suggestion in entry.suggestions)
            ):
                self.note(f"tracker: checking {attr_path} ({index}/{len(materialized)})")
                entry = PackageCacheEntry(
                    fetched_at=now,
                    suggestions=self._fetch(attr_path),
                )
                document.packages[attr_path] = entry
                self.cache.save(document)
            for suggestion in entry.suggestions:
                affected = _affected(package.version, suggestion.constraints)
                if affected is None:
                    unclassified += 1
                elif affected:
                    affected_matches.append((attr_path, suggestion, entry.fetched_at))

        issue_cache = document.open_issues
        if affected_matches and (
            issue_cache is None or now - issue_cache.fetched_at > self.max_age
        ):
            issue_cache = None
            if self.open_issues is not None:
                self.note("github: reading open nixpkgs security issues")
                try:
                    issue_cache = OpenIssuesCacheEntry(
                        fetched_at=now,
                        issue_urls=dict(self.open_issues.find_open()),
                    )
                except RiskError as error:
                    self.note(f"github: {error}; treating issue states as unknown")
                else:
                    document.open_issues = issue_cache
                    self.cache.save(document)

        findings: list[TrackerFinding] = []
        closed = 0
        unknown = 0
        for attr_path, suggestion, fetched_at in affected_matches:
            issue_url = None
            if suggestion.issue_code is not None and issue_cache is not None:
                issue_url = issue_cache.issue_urls.get(suggestion.issue_code)
                if issue_url is None and issue_cache.fetched_at >= fetched_at:
                    closed += 1
                    continue
            if issue_url is None:
                unknown += 1
            findings.append(
                TrackerFinding(
                    attr_path=attr_path,
                    identifier=suggestion.cve_id,
                    score=suggestion.score,
                    reference_url=issue_url or suggestion.reference_url,
                )
            )
        return TrackerScan(
            findings=tuple(findings),
            checked_packages=len(materialized),
            unclassified_matches=unclassified,
            closed_issue_matches=closed,
            unknown_issue_matches=unknown,
        )
