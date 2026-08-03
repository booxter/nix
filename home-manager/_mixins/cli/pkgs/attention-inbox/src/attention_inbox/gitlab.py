from __future__ import annotations

import datetime as dt
import json
import re
import subprocess
from collections.abc import Sequence
from dataclasses import dataclass
from typing import Protocol

from pydantic import BaseModel, ConfigDict, ValidationError

from attention_inbox.errors import InboxError
from attention_inbox.model import Author, InboxItem


class GitLabAuthor(BaseModel):
    model_config = ConfigDict(extra="ignore", strict=True)

    name: str | None = None
    username: str | None = None


class GitLabProject(BaseModel):
    model_config = ConfigDict(extra="ignore", strict=True)

    path_with_namespace: str | None = None
    name_with_namespace: str | None = None
    name: str | None = None


class GitLabTarget(BaseModel):
    model_config = ConfigDict(extra="ignore", strict=True)

    iid: int | str | None = None
    title: str | None = None
    name: str | None = None


class GitLabTodo(BaseModel):
    model_config = ConfigDict(extra="ignore", strict=True)

    id: int | str
    project: GitLabProject | None = None
    author: GitLabAuthor | None = None
    action_name: str | None = None
    target_type: str | None = None
    target: GitLabTarget | None = None
    target_url: str | None = None
    body: str | None = None
    created_at: str | None = None
    updated_at: str | None = None


@dataclass(frozen=True)
class CommandResult:
    returncode: int
    stdout: str
    stderr: str


class CommandRunner(Protocol):
    def run(self, arguments: Sequence[str]) -> CommandResult: ...


@dataclass(frozen=True)
class SubprocessRunner:
    def run(self, arguments: Sequence[str]) -> CommandResult:
        try:
            result = subprocess.run(
                arguments,
                check=False,
                capture_output=True,
                text=True,
            )
        except FileNotFoundError as error:
            raise InboxError("glab is not installed or is not available on PATH") from error
        return CommandResult(result.returncode, result.stdout, result.stderr)


@dataclass(frozen=True)
class GitLabTodoSource:
    """Use glab so its existing credential and hostname context stays authoritative."""

    runner: CommandRunner

    def fetch(self, hostname: str | None = None) -> list[InboxItem]:
        command = [
            "glab",
            "api",
            "todos?state=pending&per_page=100",
            "--paginate",
            "--output",
            "ndjson",
        ]
        if hostname:
            command.extend(["--hostname", hostname])
        result = self.runner.run(command)
        if result.returncode != 0:
            detail = result.stderr.strip()
            message = f"glab exited with status {result.returncode}"
            if detail:
                message += f": {detail}"
            raise InboxError(message)
        return [normalize_gitlab_todo(todo) for todo in parse_json_records(result.stdout)]


def parse_json_records(output: str) -> list[GitLabTodo]:
    records: list[GitLabTodo] = []
    for line_number, line in enumerate(output.splitlines(), start=1):
        if not line.strip():
            continue
        try:
            value: object = json.loads(line)
        except json.JSONDecodeError as error:
            raise InboxError(f"glab returned invalid JSON on output line {line_number}") from error
        values = value if isinstance(value, list) else [value]
        if not isinstance(value, (dict, list)):
            raise InboxError(f"glab returned an unexpected JSON value on output line {line_number}")
        for item in values:
            try:
                records.append(GitLabTodo.model_validate(item))
            except ValidationError as error:
                raise InboxError(
                    f"glab returned an invalid to-do item on output line {line_number}: {error}"
                ) from error
    return records


def snake_case(value: str | None) -> str:
    text = (value or "item").replace("::", "_")
    text = re.sub(r"(?<=[a-z0-9])(?=[A-Z])", "_", text)
    return re.sub(r"[^a-zA-Z0-9]+", "_", text).strip("_").lower() or "item"


def first_text(*values: str | None) -> str | None:
    for value in values:
        if value is not None and value.strip():
            return value.strip()
    return None


def normalize_timestamp(value: str | None) -> str | None:
    text = first_text(value)
    if text is None:
        return None
    try:
        parsed = dt.datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError:
        return text
    if parsed.tzinfo is None:
        return text
    return parsed.astimezone(dt.timezone.utc).isoformat().replace("+00:00", "Z")


def item_reference(kind: str, target: GitLabTarget) -> str | None:
    if target.iid is None:
        return None
    prefix = {"issue": "#", "merge_request": "!"}.get(kind, "")
    return f"{prefix}{target.iid}"


def normalize_gitlab_todo(source: GitLabTodo | object) -> InboxItem:
    try:
        todo = source if isinstance(source, GitLabTodo) else GitLabTodo.model_validate(source)
    except ValidationError as error:
        raise InboxError(f"GitLab returned an invalid to-do item: {error}") from error
    target = todo.target or GitLabTarget()
    project = todo.project or GitLabProject()
    author = todo.author or GitLabAuthor()
    kind = snake_case(todo.target_type)
    title = first_text(target.title, target.name, todo.body, todo.target_type) or "Untitled item"
    return InboxItem(
        id=f"gitlab:{todo.id}",
        source="gitlab",
        source_id=todo.id,
        kind=kind,
        reason=snake_case(todo.action_name),
        context=first_text(
            project.path_with_namespace,
            project.name_with_namespace,
            project.name,
        ),
        reference=item_reference(kind, target),
        title=title,
        body=first_text(todo.body),
        url=first_text(todo.target_url),
        author=Author(
            name=first_text(author.name),
            username=first_text(author.username),
        ),
        created_at=normalize_timestamp(todo.created_at),
        updated_at=normalize_timestamp(todo.updated_at),
    )
