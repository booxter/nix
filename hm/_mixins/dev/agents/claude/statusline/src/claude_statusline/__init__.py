"""Render live context usage and deduplicated main-session transcript usage."""

import sys
from collections.abc import Iterator
from pathlib import Path
from typing import Protocol, TextIO

from pydantic import AliasPath, BaseModel, Field, JsonValue, NonNegativeInt, ValidationError


class Status(BaseModel):
    model_name: str | None = Field(None, validation_alias=AliasPath("model", "display_name"))
    effort: str | None = Field(None, validation_alias=AliasPath("effort", "level"))
    directory: Path | None = Field(None, validation_alias=AliasPath("workspace", "current_dir"))
    input_tokens: NonNegativeInt | None = Field(
        None, validation_alias=AliasPath("context_window", "total_input_tokens")
    )
    output_tokens: NonNegativeInt | None = Field(
        None, validation_alias=AliasPath("context_window", "total_output_tokens")
    )
    used_percentage: float | None = Field(
        None, validation_alias=AliasPath("context_window", "used_percentage")
    )
    transcript_path: Path | None = None


class Usage(BaseModel):
    input_tokens: NonNegativeInt = 0
    output_tokens: NonNegativeInt = 0
    cache_creation_input_tokens: NonNegativeInt = 0
    cache_read_input_tokens: NonNegativeInt = 0

    @property
    def total_input(self) -> int:
        return self.input_tokens + self.cache_creation_input_tokens + self.cache_read_input_tokens


class Entry(BaseModel):
    type: str
    message: JsonValue = None


class Message(BaseModel):
    id: str | None = None
    usage: Usage | None = None


class TranscriptReader(Protocol):
    def lines(self, path: Path) -> Iterator[str]: ...


class LocalTranscriptReader:
    def lines(self, path: Path) -> Iterator[str]:
        with path.open() as stream:
            yield from stream


def session_usage(path: Path, reader: TranscriptReader) -> Usage | None:
    messages: dict[str, Usage] = {}
    try:
        for line in reader.lines(path):
            entry = Entry.model_validate_json(line)
            if entry.type != "assistant":
                continue

            message = Message.model_validate(entry.message)
            if message.id is not None and message.usage is not None:
                # Claude writes one entry per content block, repeating the API usage.
                # Keep the latest usage per response, including final streaming updates.
                messages[message.id] = message.usage
    except (OSError, ValidationError):
        # A missing or partially written transcript must not break the other fields
        # or turn a partial sum into an apparently complete session count.
        return None

    return Usage(
        input_tokens=sum(usage.total_input for usage in messages.values()),
        output_tokens=sum(usage.output_tokens for usage in messages.values()),
    )


def compact(tokens: int) -> str:
    for scale, suffix in ((1_000_000_000, "B"), (1_000_000, "M"), (1_000, "K")):
        if tokens >= scale:
            return f"{tokens / scale:.1f}".rstrip("0").rstrip(".") + suffix
    return str(tokens)


def render(status: Status, home: Path, reader: TranscriptReader) -> str:
    parts = [value for value in (status.model_name, status.effort) if value]
    if status.directory is not None:
        directory = status.directory
        if directory.is_relative_to(home):
            directory = Path("~") / directory.relative_to(home)
        parts.append(str(directory))

    context = []
    if status.input_tokens is not None and status.output_tokens is not None:
        context.append(f"{compact(status.input_tokens + status.output_tokens)} tokens")
    if status.used_percentage is not None:
        context.append(f"{int(100 - status.used_percentage)}% left")
    if context:
        parts.append("Context " + ", ".join(context))

    usage = session_usage(status.transcript_path, reader) if status.transcript_path else None
    if usage is not None:
        parts.append(f"Session {compact(usage.total_input)} in, {compact(usage.output_tokens)} out")
    else:
        parts.append("Session tokens unavailable")
    return " · ".join(parts)


def run(stdin: TextIO, stdout: TextIO, home: Path, reader: TranscriptReader) -> None:
    status = Status.model_validate_json(stdin.read())
    print(render(status, home, reader), file=stdout)


def main() -> None:
    run(sys.stdin, sys.stdout, Path.home(), LocalTranscriptReader())
