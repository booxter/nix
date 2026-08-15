from attention_inbox.gitlab import normalize_gitlab_todo
from attention_inbox.service import InboxService
from fakes import FakeSource, gitlab_todo


def test_collects_newest_items_first() -> None:
    source = FakeSource(
        items=[
            normalize_gitlab_todo(gitlab_todo(1, updated_at="2026-07-16T12:00:00Z")),
            normalize_gitlab_todo(gitlab_todo(2, updated_at="2026-07-16T13:00:00Z")),
        ]
    )
    items = InboxService(source).collect()
    assert [item.source_id for item in items] == [2, 1]
