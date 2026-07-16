import re
import shlex
import sys
from dataclasses import dataclass
from pathlib import Path


MAX_LINE_LENGTH = 72
FENCE_RE = re.compile(r"^\s*(```|~~~)")
TRAILER_RE = re.compile(
    r"^[A-Za-z0-9][A-Za-z0-9-]*(?:[ -][A-Za-z0-9][A-Za-z0-9-]*)*:[ \t]+\S"
)


@dataclass(frozen=True)
class Violation:
    line_number: int
    length: int
    reason: str
    text: str


def trailer_line_indexes(lines: list[str]) -> set[int]:
    """Return indexes belonging to a trailer block at the end of a message."""
    end = len(lines) - 1

    while end >= 0 and not lines[end].strip():
        end -= 1

    start = end
    while start >= 2 and lines[start].strip():
        start -= 1
    start += 1

    indexes = set(range(start, end + 1))
    saw_trailer = False
    for index in range(start, end + 1):
        line = lines[index]
        if TRAILER_RE.match(line):
            saw_trailer = True
        elif not (saw_trailer and (line.startswith(" ") or line.startswith("\t"))):
            return set()

    return indexes if saw_trailer else set()


def literal_line_indexes(lines: list[str]) -> set[int]:
    """Return indexes for fenced or indented literal content in the body."""
    indexes: set[int] = set()
    fence: str | None = None

    for index, line in enumerate(lines[2:], start=2):
        match = FENCE_RE.match(line)
        if match:
            marker = match.group(1)
            indexes.add(index)
            if fence is None:
                fence = marker
            elif marker == fence:
                fence = None
            continue

        if fence is not None or line.startswith("    ") or line.startswith("\t"):
            indexes.add(index)

    return indexes


def is_indivisible_body_line(line: str) -> bool:
    """Allow long URLs, paths, hashes, and similar single-token content."""
    stripped = line.strip()
    return bool(stripped) and not any(character.isspace() for character in stripped)


def validate_message(message: str) -> list[Violation]:
    lines = message.splitlines()
    if not lines or not lines[0].strip():
        return [Violation(1, 0, "subject must not be empty", "")]

    violations: list[Violation] = []
    subject = lines[0]
    if len(subject) > MAX_LINE_LENGTH:
        violations.append(
            Violation(
                1,
                len(subject),
                f"subject exceeds {MAX_LINE_LENGTH} characters",
                subject,
            )
        )

    if len(lines) > 1 and lines[1].strip():
        violations.append(
            Violation(
                2,
                len(lines[1]),
                "subject and body must be separated by a blank line",
                lines[1],
            )
        )

    exempt_indexes = trailer_line_indexes(lines) | literal_line_indexes(lines)
    for index, line in enumerate(lines[2:], start=2):
        if (
            len(line) <= MAX_LINE_LENGTH
            or index in exempt_indexes
            or is_indivisible_body_line(line)
        ):
            continue
        violations.append(
            Violation(
                index + 1,
                len(line),
                f"body prose exceeds {MAX_LINE_LENGTH} characters",
                line,
            )
        )

    return violations


def format_violation(violation: Violation) -> str:
    detail = f"line {violation.line_number}: {violation.reason}"
    if violation.length:
        detail += f" ({violation.length} characters)"
    return f"  {detail}\n    {violation.text}"


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(f"usage: {Path(argv[0]).name} <commit-message-file>", file=sys.stderr)
        return 2

    message_path = Path(argv[1])
    try:
        message = message_path.read_text(encoding="utf-8")
    except OSError as error:
        print(f"cannot read commit message {message_path}: {error}", file=sys.stderr)
        return 2

    violations = validate_message(message)
    if not violations:
        return 0

    print("commit message does not follow the global 50/72 format:", file=sys.stderr)
    for violation in violations:
        print(format_violation(violation), file=sys.stderr)
    print(
        "\nHard-wrap body prose by inserting newlines. Long single tokens, "
        "literal content, and terminal Git trailers are exempt.",
        file=sys.stderr,
    )
    quoted_path = shlex.quote(str(message_path))
    print(
        f"Edit {message_path}, run `git hook run commit-msg -- {quoted_path}`, "
        "then retry the commit once.",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
