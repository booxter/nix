import argparse
import json
import sys
from collections.abc import Sequence
from typing import TextIO

from attention_inbox.errors import InboxError
from attention_inbox.model import build_document
from attention_inbox.render import render_text
from attention_inbox.service import InboxService, default_service


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="attention-inbox",
        description="Show pending attention items collected from external services.",
    )
    parser.add_argument(
        "--format",
        type=str.lower,
        choices=("text", "json"),
        default="text",
        help="output format (default: text)",
    )
    parser.add_argument(
        "--gitlab-hostname",
        metavar="HOST",
        help="GitLab hostname passed to glab (default: glab context)",
    )
    return parser


def main(
    argv: Sequence[str] | None = None,
    *,
    service: InboxService | None = None,
    stdout: TextIO = sys.stdout,
    stderr: TextIO = sys.stderr,
) -> int:
    arguments = _parser().parse_args(argv)
    inbox = service or default_service()
    try:
        items = inbox.collect(arguments.gitlab_hostname)
    except InboxError as error:
        print(f"attention-inbox: {error}", file=stderr)
        return 1
    if arguments.format == "json":
        print(json.dumps(build_document(items), indent=2), file=stdout)
    else:
        stdout.write(render_text(items))
    return 0
