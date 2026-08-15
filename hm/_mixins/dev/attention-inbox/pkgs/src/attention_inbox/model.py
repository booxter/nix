from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class Author:
    name: str | None
    username: str | None


@dataclass(frozen=True)
class InboxItem:
    id: str
    source: str
    source_id: int | str
    kind: str
    reason: str
    context: str | None
    reference: str | None
    title: str
    body: str | None
    url: str | None
    author: Author
    created_at: str | None
    updated_at: str | None
