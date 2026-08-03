from package_updates.summary import (
    change_text,
    compare_from_changelogs,
    compare_from_sources,
    github_compare_url,
    github_ref,
    github_repo_url,
    markdown_link,
    normalize_git_ref,
)


def test_github_urls_are_normalized() -> None:
    assert github_repo_url("https://github.com/example/demo.git/releases?x=1") == (
        "https://github.com/example/demo"
    )
    assert github_repo_url("http://github.com/example/demo") is None
    assert github_repo_url("https://example.com/example/demo") is None
    assert github_repo_url("https://github.com/example") is None
    assert github_ref("https://github.com/example/demo/releases/tag/v1.2.3?x=1") == "v1.2.3"
    assert github_ref("https://github.com/example/demo/tree/main/") == "main"
    assert github_ref("https://github.com/example/demo/commit/abc") == "abc"
    assert github_ref("https://github.com/example/demo") is None
    assert normalize_git_ref("refs/tags/v1") == "v1"
    assert normalize_git_ref("refs/heads/main") == "main"
    assert normalize_git_ref("abc") == "abc"


def test_compare_urls_require_matching_repositories_and_changed_refs() -> None:
    assert github_compare_url("https://github.com/example/demo", "v1", "v2") == (
        "https://github.com/example/demo/compare/v1...v2"
    )
    assert github_compare_url(None, "v1", "v2") is None
    assert github_compare_url("https://github.com/example/demo", "v1", "v1") is None
    assert (
        compare_from_sources(
            "https://github.com/example/demo",
            "refs/tags/v1",
            "https://github.com/example/demo",
            "refs/tags/v2",
        )
        == "https://github.com/example/demo/compare/v1...v2"
    )
    assert (
        compare_from_sources(
            "https://github.com/example/old", "v1", "https://github.com/example/new", "v2"
        )
        is None
    )
    assert (
        compare_from_changelogs(
            "https://github.com/example/demo/releases/tag/v1",
            "https://github.com/example/demo/releases/tag/v2",
        )
        == "https://github.com/example/demo/compare/v1...v2"
    )
    assert (
        compare_from_changelogs(
            "https://example.com/v1", "https://github.com/example/demo/releases/tag/v2"
        )
        is None
    )


def test_markdown_and_change_text() -> None:
    assert markdown_link("link", "https://example.com") == "[link](https://example.com)"
    assert markdown_link("link", None) == "not set"
    assert change_text("1", "2") == "1 -> 2"
    assert change_text("2", "2") == "2"
