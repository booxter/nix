from collections.abc import Sequence
from dataclasses import dataclass, field

from attention_inbox.gitlab import CommandResult
from attention_inbox.model import InboxItem


@dataclass
class FakeRunner:
    result: CommandResult
    calls: list[list[str]] = field(default_factory=list)

    def run(self, arguments: Sequence[str]) -> CommandResult:
        self.calls.append(list(arguments))
        return self.result


@dataclass
class FakeSource:
    items: list[InboxItem] = field(default_factory=list)
    error: Exception | None = None
    hostnames: list[str | None] = field(default_factory=list)

    def fetch(self, hostname: str | None = None) -> list[InboxItem]:
        self.hostnames.append(hostname)
        if self.error is not None:
            raise self.error
        return self.items


@dataclass
class RecordingSketchybar:
    calls: list[list[str]] = field(default_factory=list)
    error: Exception | None = None

    def run(self, arguments: Sequence[str]) -> None:
        self.calls.append(list(arguments))
        if self.error is not None:
            raise self.error


def gitlab_todo(
    todo_id: int,
    *,
    action: str = "assigned",
    updated_at: str = "2026-07-16T12:00:00Z",
    title: str = "Review the change",
) -> dict[str, object]:
    return {
        "id": todo_id,
        "project": {
            "name": "Widget",
            "name_with_namespace": "Tools / Widget",
            "path_with_namespace": "tools/widget",
        },
        "author": {"name": "Ada Lovelace", "username": "ada"},
        "action_name": action,
        "target_type": "MergeRequest",
        "target": {"iid": 42, "title": title},
        "target_url": "https://gitlab.example.com/tools/widget/-/merge_requests/42",
        "body": "Please take a look.",
        "state": "pending",
        "created_at": "2026-07-16T11:00:00Z",
        "updated_at": updated_at,
    }
