from __future__ import annotations

import argparse
import json
import sys
from collections.abc import Sequence
from dataclasses import dataclass
from typing import Protocol, TextIO, cast

from pydantic import TypeAdapter, ValidationError
import semantic_version  # type: ignore[import-untyped]

from package_updates.common import print_error


class ComparableVersion(Protocol):
    def __lt__(self, other: object) -> bool: ...


class VersionFactory(Protocol):
    def __call__(self, value: str) -> ComparableVersion: ...


class VersionSpec(Protocol):
    def match(self, version: ComparableVersion) -> bool: ...


class SpecFactory(Protocol):
    def __call__(self, value: str) -> VersionSpec: ...


make_version = cast(VersionFactory, semantic_version.Version)
make_spec = cast(SpecFactory, semantic_version.NpmSpec)


@dataclass(frozen=True)
class NodeSelection:
    attribute: str
    version: str

    def as_json(self) -> str:
        return json.dumps(
            {"attribute": self.attribute, "version": self.version},
            separators=(",", ":"),
        )


def select_nodejs(
    requirement: str,
    candidates: dict[str, str],
    current_attribute: str,
) -> NodeSelection:
    specification = make_spec(requirement)
    compatible: list[tuple[ComparableVersion, str, str]] = []
    for attribute, version_text in candidates.items():
        try:
            version = make_version(version_text)
        except ValueError:
            continue
        if specification.match(version):
            compatible.append((version, attribute, version_text))

    if not compatible:
        raise ValueError(f"no available nixpkgs Node.js version satisfies {requirement!r}")

    for _, attribute, version_text in compatible:
        if attribute == current_attribute:
            return NodeSelection(attribute, version_text)

    _, attribute, version_text = max(compatible)
    return NodeSelection(attribute, version_text)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Select a nixpkgs Node.js package for an npm engine constraint."
    )
    parser.add_argument("--requirement", required=True)
    parser.add_argument("--current-attribute", required=True)
    parser.add_argument("--candidates-json", required=True)
    return parser


def run(arguments: argparse.Namespace, stdout: TextIO, stderr: TextIO) -> int:
    try:
        candidates = TypeAdapter(dict[str, str]).validate_json(arguments.candidates_json)
        selection = select_nodejs(
            arguments.requirement,
            candidates,
            arguments.current_attribute,
        )
    except (TypeError, ValueError, ValidationError) as error:
        return print_error(
            ValueError(f"cannot select Node.js for npm engine {arguments.requirement!r}: {error}"),
            stderr,
        )
    print(selection.as_json(), file=stdout)
    return 0


def main(arguments: Sequence[str] | None = None) -> int:
    return run(build_parser().parse_args(arguments), sys.stdout, sys.stderr)
