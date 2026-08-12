import json

import pytest

from attention_inbox.errors import InboxError
from attention_inbox.gitlab import (
    CommandResult,
    GitLabTodoSource,
    normalize_gitlab_todo,
    parse_json_records,
)
from fakes import FakeRunner, gitlab_todo


def test_fetches_pending_todos_as_paginated_ndjson() -> None:
    output = "\n".join(json.dumps(gitlab_todo(item)) for item in (1, 2))
    runner = FakeRunner(CommandResult(0, output, ""))
    items = GitLabTodoSource(runner).fetch("gitlab.example.com")
    assert [item.source_id for item in items] == [1, 2]
    assert runner.calls == [
        [
            "glab",
            "api",
            "todos?state=pending&per_page=100",
            "--paginate",
            "--output",
            "ndjson",
            "--hostname",
            "gitlab.example.com",
        ]
    ]


def test_fetcher_uses_glab_context_by_default() -> None:
    runner = FakeRunner(CommandResult(0, "", ""))
    GitLabTodoSource(runner).fetch()
    assert "--hostname" not in runner.calls[0]


def test_fetcher_reports_glab_errors() -> None:
    runner = FakeRunner(CommandResult(1, "", "authentication required"))
    with pytest.raises(InboxError, match="authentication required"):
        GitLabTodoSource(runner).fetch()


@pytest.mark.parametrize(
    "output",
    [
        "not-json\n",
        '"unexpected"\n',
        '[{"id": 1}, 2]\n',
        '{"id": 1, "project": "wrong"}\n',
    ],
)
def test_parse_json_records_rejects_invalid_output(output: str) -> None:
    with pytest.raises(InboxError):
        parse_json_records(output)


def test_normalizes_gitlab_fields() -> None:
    item = normalize_gitlab_todo(gitlab_todo(7, action="approval_required"))
    assert item.to_json() == {
        "id": "gitlab:7",
        "source": "gitlab",
        "source_id": 7,
        "kind": "merge_request",
        "reason": "approval_required",
        "context": "tools/widget",
        "reference": "!42",
        "title": "Review the change",
        "body": "Please take a look.",
        "url": "https://gitlab.example.com/tools/widget/-/merge_requests/42",
        "author": {"name": "Ada Lovelace", "username": "ada"},
        "created_at": "2026-07-16T11:00:00Z",
        "updated_at": "2026-07-16T12:00:00Z",
    }


def test_normalizes_offset_timestamps_to_utc() -> None:
    todo = gitlab_todo(7)
    todo["created_at"] = "2026-07-16T10:20:38.020-07:00"
    todo["updated_at"] = "2026-07-16T10:21:39.123456-07:00"
    item = normalize_gitlab_todo(todo)
    assert item.created_at == "2026-07-16T17:20:38.020000Z"
    assert item.updated_at == "2026-07-16T17:21:39.123456Z"
