#!/usr/bin/env python3

import argparse
import json
import sys

from semantic_version import NpmSpec, Version


def select_nodejs(requirement, candidates, current_attribute):
    spec = NpmSpec(requirement)
    compatible = []

    for attribute, version_text in candidates.items():
        try:
            version = Version(version_text)
        except ValueError:
            continue
        if spec.match(version):
            compatible.append((version, attribute, version_text))

    if not compatible:
        raise ValueError(
            f"no available nixpkgs Node.js version satisfies {requirement!r}"
        )

    for version, attribute, version_text in compatible:
        if attribute == current_attribute:
            return {
                "attribute": attribute,
                "version": version_text,
            }

    _, attribute, version_text = max(compatible)
    return {
        "attribute": attribute,
        "version": version_text,
    }


def main():
    parser = argparse.ArgumentParser(
        description="Select a versioned nixpkgs Node.js package for an npm engine constraint."
    )
    parser.add_argument("--requirement", required=True)
    parser.add_argument("--current-attribute", required=True)
    parser.add_argument("--candidates-json", required=True)
    args = parser.parse_args()

    try:
        candidates = json.loads(args.candidates_json)
        if not isinstance(candidates, dict):
            raise ValueError("Node.js candidates must be a JSON object")
        selection = select_nodejs(
            args.requirement,
            candidates,
            args.current_attribute,
        )
    except (ValueError, TypeError) as error:
        print(
            f"cannot select Node.js for npm engine {args.requirement!r}: {error}",
            file=sys.stderr,
        )
        return 1

    print(json.dumps(selection, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
