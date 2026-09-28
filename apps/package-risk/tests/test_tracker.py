from __future__ import annotations

from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any, cast

import httpx
import pytest
from github import Github
from github.GithubException import GithubException
from package_risk.models import MetadataRecord, PackageMeta
from package_risk.process import RiskError
from package_risk.tracker import (
    GitHubIssueResolver,
    HttpTransport,
    TrackerCache,
    TrackerCacheDocument,
    TrackerClient,
    constraint_matches,
)
from requests import ConnectionError as RequestsConnectionError


class FakeTransport:
    def __init__(self, responses: list[dict[str, Any]]) -> None:
        self.responses = responses
        self.urls: list[str] = []

    def get(self, url: str) -> dict[str, Any]:
        self.urls.append(url)
        return self.responses.pop(0)


class FakeOpenIssues:
    def __init__(self, result: dict[str, str] | RiskError) -> None:
        self.result = result
        self.calls = 0

    def find_open(self) -> dict[str, str]:
        self.calls += 1
        if isinstance(self.result, RiskError):
            raise self.result
        return self.result


def package(version: str = "1.5") -> MetadataRecord:
    return MetadataRecord(
        drvPath="/nix/store/foo.drv",
        name=f"foo-{version}",
        pname="foo",
        version=version,
        attrPath=["python313Packages", "foo"],
        meta=PackageMeta(
            maintainers=["alice"], teams=[], knownVulnerabilities=[], position="foo.nix:1"
        ),
        comparisons=[],
    )


def suggestion(
    identifier: str,
    expression: str | None,
    *,
    status: str = "affected",
    published: bool = True,
    issue_code: str | None = "NIXPKGS-2026-0001",
) -> dict[str, Any]:
    return {
        "id": int(identifier.rsplit("-", 1)[1]),
        "status": "published" if published else "accepted",
        "issue_code": issue_code,
        "cve_id": identifier,
        "affected_products": [
            {"version_constraints": [[status, expression]], "ignored": "future field"}
        ],
        "packages": {"python313Packages.foo": {}},
        "metrics": [{"base_score": 8.1}],
    }


@dataclass(frozen=True)
class FakeGitHubIssue:
    id: int
    html_url: str
    body: str | None


class FakeGitHubResults(list[FakeGitHubIssue]):
    def __init__(self, total_count: int, issues: list[FakeGitHubIssue]) -> None:
        super().__init__(issues)
        self.totalCount = total_count


class FakeGitHub:
    def __init__(
        self,
        result: FakeGitHubResults | GithubException | RequestsConnectionError,
    ) -> None:
        self.result = result
        self.queries: list[str] = []

    def search_issues(self, *, query: str) -> FakeGitHubResults:
        self.queries.append(query)
        if isinstance(self.result, Exception):
            raise self.result
        return self.result


def github_issue(identifier: int, issue_code: str) -> FakeGitHubIssue:
    return FakeGitHubIssue(
        id=identifier,
        html_url=f"https://github.com/NixOS/nixpkgs/issues/{identifier}",
        body=(
            "Nixpkgs security tracker issue: "
            f"https://tracker.security.nixos.org/issues/{issue_code}"
        ),
    )


@pytest.mark.parametrize(
    ("version", "expression", "expected"),
    [
        ("1.5", "*", True),
        ("1.5", "=<1.5", True),
        ("1.5", "==1.5", True),
        ("1.5", "==>= 1.0, < 2.0", True),
        ("2.0", ">= 1.0, < 2.0", False),
        ("1.5", ">1.5", False),
        ("1.5", "<=1.4", False),
        ("1.5", "=1.5", True),
        ("v1.5", "1.5", True),
        ("1.5pre1", "<1.5", True),
        ("1.5-unstable-2026-01-01", "=1.5", True),
        ("unstable-2026-01-01", "=1.5", None),
        ("1.5", "bogus relation ???", None),
        ("1.5", None, None),
    ],
)
def test_constraint_matches(version: str, expression: str | None, expected: bool | None) -> None:
    assert constraint_matches(version, expression) is expected


def test_tracker_scan_fetches_paginates_and_caches(tmp_path: Path) -> None:
    transport = FakeTransport(
        [
            {
                "next": (
                    "http://tracker.security.nixos.org/api/v1/suggestions?"
                    "page=2&status=published&package=python313Packages.foo"
                ),
                "results": [suggestion("CVE-2026-1001", "==>= 1.0, < 2.0")],
            },
            {
                "next": None,
                "results": [
                    suggestion("CVE-2026-1002", None),
                    suggestion("CVE-2026-1003", "*", published=False),
                    {
                        **suggestion("CVE-2026-1004", "*"),
                        "packages": {"other": {}},
                    },
                ],
            },
        ]
    )
    cache = TrackerCache(tmp_path / "cache" / "tracker.json")
    notes: list[str] = []
    open_issues = FakeOpenIssues(
        {
            "NIXPKGS-2026-0001": "https://github.com/NixOS/nixpkgs/issues/1234",
        }
    )
    client = TrackerClient(
        transport,
        cache,
        note=notes.append,
        open_issues=open_issues,
        now=lambda: datetime(2026, 9, 27, tzinfo=UTC),
    )

    result = client.scan([package()])

    assert [finding.identifier for finding in result.findings] == ["CVE-2026-1001"]
    assert result.findings[0].score == 8.1
    assert result.checked_packages == 1
    assert result.unclassified_matches == 1
    assert result.closed_issue_matches == 0
    assert result.unknown_issue_matches == 0
    assert result.findings[0].reference_url == "https://github.com/NixOS/nixpkgs/issues/1234"
    assert len(transport.urls) == 2
    assert "package=python313Packages.foo" in transport.urls[0]
    assert transport.urls[1].endswith("&page=2")
    assert notes == [
        "tracker: checking python313Packages.foo (1/1)",
        "github: reading open nixpkgs security issues",
    ]
    assert open_issues.calls == 1

    cached = client.scan([package()])
    assert cached == result
    assert len(transport.urls) == 2
    assert open_issues.calls == 1


def test_tracker_omits_matches_with_closed_issues(tmp_path: Path) -> None:
    transport = FakeTransport(
        [
            {
                "next": None,
                "results": [
                    suggestion("CVE-2026-1001", "<2.0"),
                    suggestion(
                        "CVE-2026-1002",
                        "<2.0",
                        issue_code="NIXPKGS-2026-0002",
                    ),
                ],
            }
        ]
    )
    client = TrackerClient(
        transport,
        TrackerCache(tmp_path / "tracker.json"),
        note=lambda _message: None,
        open_issues=FakeOpenIssues(
            {
                "NIXPKGS-2026-0001": "https://github.com/NixOS/nixpkgs/issues/1234",
            }
        ),
        now=lambda: datetime(2026, 9, 27, tzinfo=UTC),
    )

    result = client.scan([package()])

    assert [finding.identifier for finding in result.findings] == ["CVE-2026-1001"]
    assert result.closed_issue_matches == 1
    assert result.unknown_issue_matches == 0


def test_tracker_keeps_matches_when_issue_lookup_fails(tmp_path: Path) -> None:
    notes: list[str] = []
    client = TrackerClient(
        FakeTransport([{"next": None, "results": [suggestion("CVE-2026-1001", "<2.0")]}]),
        TrackerCache(tmp_path / "tracker.json"),
        note=notes.append,
        open_issues=FakeOpenIssues(RiskError("offline")),
        now=lambda: datetime(2026, 9, 27, tzinfo=UTC),
    )

    result = client.scan([package()])

    assert [finding.identifier for finding in result.findings] == ["CVE-2026-1001"]
    assert result.closed_issue_matches == 0
    assert result.unknown_issue_matches == 1
    assert result.findings[0].reference_url.startswith("https://tracker.security.nixos.org/")
    assert notes[-1] == "github: offline; treating issue states as unknown"


def test_tracker_keeps_matches_without_issue_codes(tmp_path: Path) -> None:
    client = TrackerClient(
        FakeTransport(
            [
                {
                    "next": None,
                    "results": [
                        suggestion("CVE-2026-1001", "<2.0", issue_code=None),
                    ],
                }
            ]
        ),
        TrackerCache(tmp_path / "tracker.json"),
        note=lambda _message: None,
        open_issues=FakeOpenIssues({}),
        now=lambda: datetime(2026, 9, 27, tzinfo=UTC),
    )

    result = client.scan([package()])

    assert len(result.findings) == 1
    assert result.closed_issue_matches == 0
    assert result.unknown_issue_matches == 1


def test_tracker_refreshes_stale_entry(tmp_path: Path) -> None:
    transport = FakeTransport(
        [
            {"next": None, "results": []},
            {"next": None, "results": [suggestion("CVE-2026-1001", "<2.0")]},
        ]
    )
    current = datetime(2026, 9, 27, tzinfo=UTC)
    client = TrackerClient(
        transport,
        TrackerCache(tmp_path / "tracker.json"),
        note=lambda _message: None,
        max_age=timedelta(hours=1),
        now=lambda: current,
    )
    assert not client.scan([package()]).findings

    current += timedelta(hours=2)
    assert client.scan([package()]).findings
    assert len(transport.urls) == 2


def test_github_issue_resolver_maps_search_results() -> None:
    items = [
        github_issue(identifier, f"NIXPKGS-2026-{identifier:04d}") for identifier in range(1, 102)
    ]
    items[0] = FakeGitHubIssue(
        id=1,
        html_url="https://github.com/NixOS/nixpkgs/issues/1",
        body=(
            "[Nixpkgs security tracker issue]"
            "(https://tracker.security.nixos.org//issues/NIXPKGS-2026-0001)"
        ),
    )
    github = FakeGitHub(FakeGitHubResults(101, items))

    result = GitHubIssueResolver(cast(Github, github)).find_open()

    assert len(result) == 101
    assert result["NIXPKGS-2026-0101"].endswith("/101")
    assert github.queries == [
        'repo:NixOS/nixpkgs is:issue is:open "Nixpkgs security tracker issue" in:body'
    ]


@pytest.mark.parametrize(
    ("results", "message"),
    [
        (
            FakeGitHubResults(1_001, []),
            "1,000-result",
        ),
        (
            FakeGitHubResults(1, []),
            "changed while",
        ),
        (
            FakeGitHubResults(
                1,
                [
                    FakeGitHubIssue(
                        id=1,
                        html_url="https://github.com/NixOS/nixpkgs/issues/1",
                        body="missing tracker link",
                    )
                ],
            ),
            "without a tracker code",
        ),
    ],
)
def test_github_issue_resolver_rejects_incomplete_results(
    results: FakeGitHubResults, message: str
) -> None:
    with pytest.raises(RiskError, match=message):
        GitHubIssueResolver(cast(Github, FakeGitHub(results))).find_open()


@pytest.mark.parametrize(
    "error",
    [
        GithubException(500, {"message": "failed"}),
        RequestsConnectionError("offline"),
    ],
)
def test_github_issue_resolver_reports_library_errors(
    error: GithubException | RequestsConnectionError,
) -> None:
    with pytest.raises(RiskError, match="GitHub issue lookup failed"):
        GitHubIssueResolver(cast(Github, FakeGitHub(error))).find_open()


def test_tracker_rejects_bad_pagination_url(tmp_path: Path) -> None:
    client = TrackerClient(
        FakeTransport([{"next": "https://evil.example/data", "results": []}]),
        TrackerCache(tmp_path / "tracker.json"),
        note=lambda _message: None,
    )
    with pytest.raises(RiskError, match="pagination"):
        client.scan([package()])


def test_tracker_rejects_invalid_response(tmp_path: Path) -> None:
    client = TrackerClient(
        FakeTransport([{"results": "wrong"}]),
        TrackerCache(tmp_path / "tracker.json"),
        note=lambda _message: None,
    )
    with pytest.raises(RiskError, match="could not parse"):
        client.scan([package()])


def test_tracker_cache_reports_invalid_data(tmp_path: Path) -> None:
    path = tmp_path / "tracker.json"
    path.write_text("not json")
    with pytest.raises(RiskError, match="could not read"):
        TrackerCache(path).load()


def test_tracker_cache_reports_write_failure(tmp_path: Path) -> None:
    parent = tmp_path / "not-a-directory"
    parent.write_text("file")
    with pytest.raises(RiskError, match="could not write"):
        TrackerCache(parent / "tracker.json").save(TrackerCacheDocument())


def http_client(responses: list[httpx.Response | Exception]) -> httpx.Client:
    def handle(request: httpx.Request) -> httpx.Response:
        response = responses.pop(0)
        if isinstance(response, Exception):
            raise response
        return response

    return httpx.Client(transport=httpx.MockTransport(handle))


def test_http_transport_retries_rate_limit() -> None:
    notes: list[str] = []
    sleeps: list[float] = []
    client = http_client(
        [
            httpx.Response(429, headers={"Retry-After": "invalid"}),
            httpx.Response(200, json={"ok": True}),
        ]
    )
    transport = HttpTransport(
        token="secret",
        note=notes.append,
        sleeper=sleeps.append,
        client=client,
    )
    assert transport.get("https://tracker.example/") == {"ok": True}
    assert sleeps == [60.0]
    assert notes == ["NixOS Security Tracker rate limit reached; retrying in 60s"]
    transport.close()


def test_http_transport_rejects_persistent_rate_limit() -> None:
    transport = HttpTransport(
        token=None,
        note=lambda _message: None,
        sleeper=lambda _delay: None,
        client=http_client([httpx.Response(429)] * 4),
    )
    with pytest.raises(RiskError, match="persisted"):
        transport.get("https://tracker.example/")


@pytest.mark.parametrize(
    "response",
    [
        httpx.Response(500),
        httpx.Response(200, text="not json"),
        httpx.Response(200, json=[]),
        httpx.ConnectError("offline"),
    ],
)
def test_http_transport_reports_bad_responses(response: httpx.Response | Exception) -> None:
    transport = HttpTransport(
        token=None,
        note=lambda _message: None,
        client=http_client([response]),
    )
    with pytest.raises(RiskError, match="Tracker"):
        transport.get("https://tracker.example/")
