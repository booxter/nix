from dataclasses import dataclass
from typing import Protocol

from attention_inbox.gitlab import GitLabTodoSource, SubprocessRunner
from attention_inbox.model import InboxItem


class TodoSource(Protocol):
    def fetch(self, hostname: str | None = None) -> list[InboxItem]: ...


@dataclass(frozen=True)
class InboxService:
    source: TodoSource

    def collect(self, hostname: str | None = None) -> list[InboxItem]:
        return sorted(
            self.source.fetch(hostname),
            key=lambda item: item.updated_at or item.created_at or "",
            reverse=True,
        )


def default_service() -> InboxService:
    return InboxService(GitLabTodoSource(SubprocessRunner()))
