from __future__ import annotations

import argparse
import json
import sys
from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import TextIO, TypedDict

from atomic_file_writes import write_text_atomic


class ProvisionError(RuntimeError):
    pass


class PersonProvision(TypedDict):
    mailAddresses: list[str]


class ProvisionDocument(TypedDict):
    persons: dict[str, PersonProvision]


class Arguments(argparse.Namespace):
    output: Path
    person_mail: list[str]


@dataclass(frozen=True)
class MailSource:
    person: str
    path: Path


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="kanidm-person-mail-provision",
        description="Render person mail addresses as Kanidm provisioning JSON.",
    )
    parser.add_argument("output", type=Path, metavar="OUTPUT")
    parser.add_argument(
        "person_mail",
        nargs="+",
        metavar="PERSON_OR_MAIL_FILE",
        help="One or more PERSON MAIL_FILE pairs.",
    )
    return parser


def parse_arguments(argv: Sequence[str] | None = None) -> tuple[Path, tuple[MailSource, ...]]:
    parser = build_parser()
    arguments = parser.parse_args(argv, namespace=Arguments())
    if len(arguments.person_mail) % 2 != 0:
        parser.error("expected PERSON MAIL_FILE pairs")

    sources = tuple(
        MailSource(person, Path(mail_file))
        for person, mail_file in zip(
            arguments.person_mail[::2], arguments.person_mail[1::2], strict=True
        )
    )
    return arguments.output, sources


def read_mail_address(source: MailSource) -> str:
    try:
        metadata = source.path.stat()
    except OSError as error:
        raise ProvisionError(
            f"mail address file is empty or missing for {source.person}: {source.path}"
        ) from error

    if not source.path.is_file() or metadata.st_size == 0:
        raise ProvisionError(
            f"mail address file is empty or missing for {source.person}: {source.path}"
        )

    try:
        address = source.path.read_text(encoding="utf-8").rstrip("\r\n")
    except (OSError, UnicodeError) as error:
        raise ProvisionError(
            f"failed to read mail address for {source.person}: {source.path}"
        ) from error

    if not address:
        raise ProvisionError(f"empty mail address for {source.person}: {source.path}")
    return address


def render_document(sources: Sequence[MailSource]) -> ProvisionDocument:
    persons: dict[str, PersonProvision] = {}
    for source in sources:
        persons[source.person] = {"mailAddresses": [read_mail_address(source)]}
    return {"persons": persons}


def write_document(output: Path, document: ProvisionDocument) -> None:
    write_text_atomic(output, json.dumps(document, separators=(",", ":")) + "\n")


def provision(output: Path, sources: Sequence[MailSource]) -> None:
    if not output.parent.is_dir():
        raise ProvisionError(f"output directory does not exist: {output.parent}")
    write_document(output, render_document(sources))


def main(argv: Sequence[str] | None = None, *, stderr: TextIO | None = None) -> int:
    output, sources = parse_arguments(argv)
    try:
        provision(output, sources)
    except ProvisionError as error:
        print(error, file=stderr or sys.stderr)
        return 1
    return 0
