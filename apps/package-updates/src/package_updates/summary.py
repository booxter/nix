from __future__ import annotations

from urllib.parse import urlsplit


def github_repo_url(url: str) -> str | None:
    parsed = urlsplit(url)
    if parsed.scheme != "https" or parsed.netloc != "github.com":
        return None
    components = [component for component in parsed.path.split("/") if component]
    if len(components) < 2:
        return None
    owner, repository = components[:2]
    repository = repository.removesuffix(".git")
    if not owner or not repository:
        return None
    return f"https://github.com/{owner}/{repository}"


def github_ref(url: str) -> str | None:
    path = urlsplit(url).path.rstrip("/")
    for marker in ("/releases/tag/", "/tree/", "/commit/"):
        if marker in path:
            reference = path.split(marker, maxsplit=1)[1]
            return reference or None
    return None


def normalize_git_ref(reference: str) -> str:
    for prefix in ("refs/tags/", "refs/heads/"):
        if reference.startswith(prefix):
            return reference.removeprefix(prefix)
    return reference


def github_compare_url(repository: str | None, old_ref: str, new_ref: str) -> str | None:
    old_ref = normalize_git_ref(old_ref)
    new_ref = normalize_git_ref(new_ref)
    if repository and old_ref and new_ref and old_ref != new_ref:
        return f"{repository}/compare/{old_ref}...{new_ref}"
    return None


def compare_from_sources(
    old_source: str,
    old_ref: str,
    new_source: str,
    new_ref: str,
) -> str | None:
    old_repository = github_repo_url(old_source)
    new_repository = github_repo_url(new_source)
    if old_repository and new_repository and old_repository != new_repository:
        return None
    return github_compare_url(new_repository or old_repository, old_ref, new_ref)


def compare_from_changelogs(old_changelog: str, new_changelog: str) -> str | None:
    old_repository = github_repo_url(old_changelog)
    new_repository = github_repo_url(new_changelog)
    if not old_repository or old_repository != new_repository:
        return None
    return github_compare_url(
        new_repository,
        github_ref(old_changelog) or "",
        github_ref(new_changelog) or "",
    )


def markdown_link(label: str, url: str | None) -> str:
    return f"[{label}]({url})" if url else "not set"


def change_text(old_value: str, new_value: str) -> str:
    if old_value and old_value != new_value:
        return f"{old_value} -> {new_value}"
    return new_value
