from __future__ import annotations

from collections import Counter
from dataclasses import dataclass
from typing import TypeAlias


JsonValue: TypeAlias = None | bool | int | float | str | list["JsonValue"] | dict[str, "JsonValue"]
JsonObject: TypeAlias = dict[str, JsonValue]
SCHEMA_VERSION = 1


@dataclass(frozen=True)
class Author:
    name: str | None
    username: str | None

    def to_json(self) -> JsonObject:
        return {"name": self.name, "username": self.username}


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

    def to_json(self) -> JsonObject:
        return {
            "id": self.id,
            "source": self.source,
            "source_id": self.source_id,
            "kind": self.kind,
            "reason": self.reason,
            "context": self.context,
            "reference": self.reference,
            "title": self.title,
            "body": self.body,
            "url": self.url,
            "author": self.author.to_json(),
            "created_at": self.created_at,
            "updated_at": self.updated_at,
        }


def build_document(items: list[InboxItem]) -> JsonObject:
    counts = Counter(item.source for item in items)
    return {
        "schema_version": SCHEMA_VERSION,
        "summary": {
            "total": len(items),
            "by_source": dict(sorted(counts.items())),
        },
        "items": [item.to_json() for item in items],
    }
