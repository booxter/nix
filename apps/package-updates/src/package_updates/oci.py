from __future__ import annotations

import argparse
import os
import re
import sys
from collections.abc import Sequence
from pathlib import Path
from typing import Protocol, TextIO

from natsort import natsorted
from pydantic import ValidationError

from package_updates.common import (
    Runner,
    SubprocessRunner,
    ToolPaths,
    UpdateError,
    atomic_write_json,
    checked,
    find_repo_root,
    print_error,
)
from package_updates.models import (
    ImageConfig,
    OciPin,
    OciPins,
    PrefetchedImage,
    SkopeoTags,
)
from package_updates.summary import (
    change_text,
    compare_from_changelogs,
    compare_from_sources,
    markdown_link,
)

SUMMARY_HEADER = """Automated OCI image tag update.

OCI images were prefetched for linux/amd64 and pinned as Nix fixed-output
archives. Normal CI is expected to validate whether the updated image still
works with the managed service.

| Target | Image | Tag | Digest | Nix hash | Changelog | Diff |
| --- | --- | --- | --- | --- | --- | --- |
"""
SOURCE_LABEL = "org.opencontainers.image.source"
REVISION_LABEL = "org.opencontainers.image.revision"


class OciBackend(Protocol):
    def list_tags(self, image: str) -> tuple[str, ...]: ...

    def prefetch(self, image: str, tag: str) -> PrefetchedImage: ...

    def labels(self, image: str, tag: str, digest: str) -> dict[str, str]: ...


class CommandOciBackend:
    def __init__(self, repo_root: Path, tools: ToolPaths, runner: Runner) -> None:
        self.repo_root = repo_root
        self.tools = tools
        self.runner = runner

    def list_tags(self, image: str) -> tuple[str, ...]:
        output = checked(
            self.runner.run(
                [self.tools.skopeo, "list-tags", f"docker://{image}"],
                cwd=self.repo_root,
            ),
            f"registry tag lookup for {image}",
        )
        return SkopeoTags.model_validate_json(output).tags

    def prefetch(self, image: str, tag: str) -> PrefetchedImage:
        output = checked(
            self.runner.run(
                [
                    self.tools.nix_prefetch_docker,
                    "--json",
                    "--quiet",
                    "--os",
                    "linux",
                    "--arch",
                    "amd64",
                    "--image-name",
                    image,
                    "--image-tag",
                    tag,
                    "--final-image-name",
                    image,
                    "--final-image-tag",
                    tag,
                ],
                cwd=self.repo_root,
            ),
            f"prefetch for {image}:{tag}",
        )
        return PrefetchedImage.model_validate_json(output)

    def labels(self, image: str, tag: str, digest: str) -> dict[str, str]:
        reference = f"docker://{image}@{digest}" if digest else f"docker://{image}:{tag}"
        result = self.runner.run(
            [self.tools.skopeo, "inspect", "--config", reference],
            cwd=self.repo_root,
        )
        if result.returncode != 0:
            return {}
        return ImageConfig.model_validate_json(result.stdout).merged_labels()


def load_pins(path: Path) -> OciPins:
    return OciPins.model_validate_json(path.read_text())


def selected_pins(
    pins: OciPins,
    target_filter: str | None,
) -> tuple[tuple[str, OciPin], ...]:
    selected = tuple(
        (name, pin.model_copy(deep=True))
        for name, pin in pins.root.items()
        if target_filter is None or name == target_filter
    )
    if not selected:
        raise UpdateError("No OCI image targets matched.")
    return selected


def latest_tag(image: str, pattern: str, tags: Sequence[str]) -> str:
    try:
        expression = re.compile(pattern)
    except re.error as error:
        raise UpdateError(f"Invalid tag regex for {image}: {pattern}: {error}") from error
    matching = [tag for tag in tags if expression.search(tag)]
    if not matching:
        raise UpdateError(f"No tags for {image} matched regex: {pattern}")
    return natsorted(matching)[-1]


def changelog_for(template: str, tag: str) -> str:
    return template.replace("{tag}", tag)


def image_diff_url(
    backend: OciBackend,
    image: str,
    old: OciPin,
    new_tag: str,
    new_digest: str,
) -> str | None:
    if old.tag == new_tag:
        return None
    old_labels = backend.labels(image, old.tag, old.digest)
    new_labels = backend.labels(image, new_tag, new_digest)
    return compare_from_sources(
        old_labels.get(SOURCE_LABEL, ""),
        old_labels.get(REVISION_LABEL, ""),
        new_labels.get(SOURCE_LABEL, ""),
        new_labels.get(REVISION_LABEL, ""),
    ) or compare_from_changelogs(
        changelog_for(old.changelog, old.tag),
        changelog_for(old.changelog, new_tag),
    )


def summary_row(
    name: str,
    old: OciPin,
    new_tag: str,
    new_digest: str,
    new_hash: str,
    comparison: str | None,
) -> str:
    changelog = changelog_for(old.changelog, new_tag)
    return (
        f"| `{name}` | `{old.image}` | `{change_text(old.tag, new_tag)}` | "
        f"`{change_text(old.digest, new_digest)}` | "
        f"`{change_text(old.hash, new_hash)}` | {markdown_link('link', changelog)} | "
        f"{markdown_link('compare', comparison)} |\n"
    )


def update_oci_images(
    pins: OciPins,
    selected: Sequence[tuple[str, OciPin]],
    pins_file: Path,
    summary_file: Path,
    backend: OciBackend,
    stdout: TextIO,
) -> None:
    summary_file.parent.mkdir(parents=True, exist_ok=True)
    summary_file.write_text(SUMMARY_HEADER)
    with summary_file.open("a") as summary:
        for name, old in selected:
            print(f"::group::Updating OCI image {name}", file=stdout)
            print(f"image: {old.image}", file=stdout)
            print(f"old tag: {old.tag}", file=stdout)
            print(f"tag regex: {old.tag_regex}", file=stdout)
            new_tag = latest_tag(old.image, old.tag_regex, backend.list_tags(old.image))
            print(f"new tag: {new_tag}", file=stdout)
            prefetched = backend.prefetch(old.image, new_tag)
            print(f"new digest: {prefetched.image_digest}", file=stdout)
            print(f"new hash: {prefetched.hash}", file=stdout)
            comparison = image_diff_url(
                backend,
                old.image,
                old,
                new_tag,
                prefetched.image_digest,
            )
            current = pins.root[name]
            current.tag = new_tag
            current.digest = prefetched.image_digest
            current.hash = prefetched.hash
            if current.model_dump() != old.model_dump():
                atomic_write_json(
                    pins_file,
                    pins.model_dump(mode="json", by_alias=True),
                )
            print("::endgroup::", file=stdout)
            summary.write(
                summary_row(
                    name,
                    old,
                    new_tag,
                    prefetched.image_digest,
                    prefetched.hash,
                    comparison,
                )
            )
        summary.write("\nGenerated by GitHub Actions.\n")
    print(f"Wrote OCI image update summary: {summary_file}", file=stdout)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=("Update pinned OCI image tags from the registry and write a Markdown summary.")
    )
    parser.add_argument("--summary-file", type=Path)
    parser.add_argument("--pins-file", type=Path)
    parser.add_argument("--target")
    parser.add_argument("--list-targets", action="store_true")
    return parser


def main(cli_arguments: Sequence[str] | None = None) -> int:
    arguments = build_parser().parse_args(cli_arguments)
    try:
        repo_root = find_repo_root(Path.cwd())
        pins_file = arguments.pins_file or Path(
            os.environ.get("OCI_IMAGE_PINS_FILE", repo_root / "lib/oci-images/images.json")
        )
        pins = load_pins(pins_file)
        if arguments.list_targets:
            for name, pin in pins.root.items():
                print(f"{name}\t{pin.image}:{pin.tag}")
            return 0
        summary_file = arguments.summary_file or Path(
            os.environ.get(
                "OCI_IMAGE_UPDATE_SUMMARY_FILE",
                repo_root / "oci-image-update-summary.md",
            )
        )
        selected = selected_pins(pins, arguments.target)
        backend = CommandOciBackend(repo_root, ToolPaths.from_environment(), SubprocessRunner())
        update_oci_images(
            pins,
            selected,
            pins_file,
            summary_file,
            backend,
            sys.stdout,
        )
    except (OSError, UpdateError, ValidationError) as error:
        return print_error(error, sys.stderr)
    return 0
