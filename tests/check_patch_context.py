#!/usr/bin/env python3

import argparse
import re
from dataclasses import dataclass
from pathlib import Path


PATCH_SUFFIXES = {".diff", ".patch"}
HUNK_HEADER = re.compile(
    r"^@@ -\d+(?:,(?P<old_count>\d+))? "
    r"\+\d+(?:,(?P<new_count>\d+))? @@"
)


@dataclass(frozen=True)
class ContextlessHunk:
    line: int
    header: str


def find_contextless_hunks(patch: str) -> list[ContextlessHunk]:
    violations: list[ContextlessHunk] = []
    old_path: str | None = None
    hunk_line: int | None = None
    hunk_header = ""
    hunk_has_context = False
    hunk_creates_file = False
    old_remaining = 0
    new_remaining = 0

    def finish_hunk() -> None:
        nonlocal hunk_line
        if hunk_line is not None and not hunk_creates_file and not hunk_has_context:
            violations.append(ContextlessHunk(hunk_line, hunk_header))
        hunk_line = None

    for line_number, line in enumerate(patch.splitlines(), 1):
        if hunk_line is not None:
            if line.startswith(" ") or not line:
                hunk_has_context = True
                old_remaining -= 1
                new_remaining -= 1
            elif line.startswith("-"):
                old_remaining -= 1
            elif line.startswith("+"):
                new_remaining -= 1
            else:
                raise ValueError(
                    f"line {line_number}: malformed line inside hunk: {line!r}"
                )

            if old_remaining < 0 or new_remaining < 0:
                raise ValueError(
                    f"line {line_number}: hunk contains more lines than its header"
                )

            if old_remaining == 0 and new_remaining == 0:
                finish_hunk()
            continue

        if line.startswith("diff --git "):
            old_path = None
            continue

        if line.startswith("--- "):
            old_path = line.removeprefix("--- ").split("\t", 1)[0]
            continue

        match = HUNK_HEADER.match(line)
        if match:
            hunk_line = line_number
            hunk_header = line
            hunk_has_context = False
            hunk_creates_file = old_path == "/dev/null"
            old_remaining = int(match.group("old_count") or 1)
            new_remaining = int(match.group("new_count") or 1)
        elif line.startswith("@@"):
            raise ValueError(f"line {line_number}: unsupported hunk header: {line}")

    if hunk_line is not None and (old_remaining or new_remaining):
        raise ValueError(f"line {hunk_line}: hunk ends before its declared line count")
    finish_hunk()
    return violations


def patch_files(root: Path) -> list[Path]:
    return sorted(
        path
        for path in root.rglob("*")
        if path.is_file()
        and path.suffix in PATCH_SUFFIXES
        and ".git" not in path.relative_to(root).parts
    )


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Reject patch hunks without unchanged source context."
    )
    parser.add_argument("root", nargs="?", type=Path, default=Path.cwd())
    args = parser.parse_args()

    root = args.root.resolve()
    paths = patch_files(root)
    failures = 0

    for path in paths:
        relative_path = path.relative_to(root)
        try:
            contextless_hunks = find_contextless_hunks(path.read_text())
        except ValueError as error:
            failures += 1
            print(f"{relative_path}: {error}")
            continue

        for hunk in contextless_hunks:
            failures += 1
            print(
                f"{relative_path}:{hunk.line}: hunk has no unchanged context: {hunk.header}"
            )

    if failures:
        print(
            f"Found {failures} context-free edit hunk(s). Regenerate them with "
            "unified context (for example, git diff -U3). New-file hunks are "
            "exempt."
        )
        return 1

    print(f"Checked {len(paths)} patch file(s): every edit hunk has unchanged context.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
