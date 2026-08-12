from attention_inbox.model import Author, InboxItem, build_document
from attention_inbox.gitlab import normalize_gitlab_todo
from attention_inbox.render import render_text
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


def item() -> InboxItem:
    return InboxItem(
        id="gitlab:7",
        source="gitlab",
        source_id=7,
        kind="merge_request",
        reason="build_failed",
        context="tools/widget",
        reference="!42",
        title="Review the change",
        body=None,
        url="https://gitlab.example.com/tools/widget/-/merge_requests/42",
        author=Author(name="Ada Lovelace", username="ada"),
        created_at="2026-07-16T11:00:00Z",
        updated_at="2026-07-16T12:00:00Z",
    )


def test_renders_human_readable_and_empty_inboxes() -> None:
    output = render_text([item()])
    assert "1 pending item:" in output
    assert "[gitlab] Build failed · tools/widget!42 · Review the change" in output
    assert item().url in output
    assert render_text([]) == "No pending items.\n"


def test_json_document_has_versioned_summary() -> None:
    document = build_document([item()])
    assert document["schema_version"] == 1
    assert document["summary"] == {"total": 1, "by_source": {"gitlab": 1}}
    assert document["items"] == [item().to_json()]
