"""Render live context usage and deduplicated main-session transcript usage."""

import sys
from bisect import bisect_right
from collections.abc import Iterable, Iterator
from dataclasses import dataclass, field
from datetime import datetime
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
    timestamp: datetime | None = None
    message: JsonValue = None


class Message(BaseModel):
    id: str | None = None
    usage: Usage | None = None


@dataclass
class Response:
    usage: Usage
    block_times: list[datetime] = field(default_factory=list)


@dataclass(frozen=True)
class SessionUsage:
    input_tokens: int
    output_tokens: int
    tokens_per_second: float | None


class TranscriptReader(Protocol):
    def lines(self, path: Path) -> Iterator[str]: ...


class LocalTranscriptReader:
    def lines(self, path: Path) -> Iterator[str]:
        with path.open() as stream:
            yield from stream


def session_usage(path: Path, reader: TranscriptReader) -> SessionUsage | None:
    request_times: list[datetime] = []
    responses: dict[str, Response] = {}
    try:
        for line in reader.lines(path):
            entry = Entry.model_validate_json(line)
            if entry.type == "api-request" and entry.timestamp is not None:
                request_times.append(entry.timestamp)
                continue

            if entry.type != "assistant":
                continue

            message = Message.model_validate(entry.message)
            if message.id is None or message.usage is None:
                continue

            # Claude writes one entry per content block, repeating the API usage.
            # Keep the latest usage per response, including final streaming updates.
            response = responses.setdefault(message.id, Response(message.usage))
            response.usage = message.usage
            if entry.timestamp is not None:
                response.block_times.append(entry.timestamp)
    except (OSError, ValidationError):
        # A missing or partially written transcript must not break the other fields
        # or turn a partial sum into an apparently complete session count.
        return None

    return SessionUsage(
        input_tokens=sum(response.usage.total_input for response in responses.values()),
        output_tokens=sum(response.usage.output_tokens for response in responses.values()),
        tokens_per_second=output_rate(request_times, responses.values()),
    )


def output_rate(request_times: list[datetime], responses: Iterable[Response]) -> float | None:
    """Return output tokens per second, timing each response from its request.

    A response's blocks can land in the file after the next request's entry, so
    file order cannot pair them. Pair each response with the latest request sent
    before its first block instead.
    """
    request_times = sorted(request_times)
    tokens = 0
    seconds = 0.0
    for response in responses:
        if not response.block_times:
            continue

        index = bisect_right(request_times, min(response.block_times))
        if index == 0:
            # Older Claude versions did not log requests; leave such responses untimed.
            continue

        tokens += response.usage.output_tokens
        seconds += (max(response.block_times) - request_times[index - 1]).total_seconds()

    if seconds <= 0:
        return None
    return tokens / seconds


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
        session = f"Session {compact(usage.input_tokens)} in, {compact(usage.output_tokens)} out"
        if usage.tokens_per_second is not None:
            session += f", {usage.tokens_per_second:.1f} tk/s"
        parts.append(session)
    else:
        parts.append("Session tokens unavailable")
    return " · ".join(parts)


def run(stdin: TextIO, stdout: TextIO, home: Path, reader: TranscriptReader) -> None:
    status = Status.model_validate_json(stdin.read())
    print(render(status, home, reader), file=stdout)


def main() -> None:
    run(sys.stdin, sys.stdout, Path.home(), LocalTranscriptReader())
