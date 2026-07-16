import contextlib
import io
import json
import subprocess
import unittest
from unittest import mock

import main as attention_inbox


def gitlab_todo(
    todo_id,
    *,
    action="assigned",
    updated_at="2026-07-16T12:00:00Z",
    title="Review the change",
):
    return {
        "id": todo_id,
        "project": {
            "name": "Widget",
            "name_with_namespace": "Tools / Widget",
            "path_with_namespace": "tools/widget",
        },
        "author": {
            "name": "Ada Lovelace",
            "username": "ada",
        },
        "action_name": action,
        "target_type": "MergeRequest",
        "target": {
            "iid": 42,
            "title": title,
        },
        "target_url": "https://gitlab.example.com/tools/widget/-/merge_requests/42",
        "body": "Please take a look.",
        "state": "pending",
        "created_at": "2026-07-16T11:00:00Z",
        "updated_at": updated_at,
    }


class AttentionInboxTests(unittest.TestCase):
    def test_fetches_all_pending_todos_as_ndjson(self):
        calls = []

        def runner(command, **kwargs):
            calls.append((command, kwargs))
            output = "\n".join(json.dumps(gitlab_todo(item)) for item in (1, 2))
            return subprocess.CompletedProcess(command, 0, output, "")

        todos = attention_inbox.fetch_gitlab_todos("gitlab.example.com", runner=runner)

        self.assertEqual([todo["id"] for todo in todos], [1, 2])
        self.assertEqual(
            calls[0][0],
            [
                "glab",
                "api",
                "todos?state=pending&per_page=100",
                "--paginate",
                "--output",
                "ndjson",
                "--hostname",
                "gitlab.example.com",
            ],
        )
        self.assertTrue(calls[0][1]["text"])

    def test_fetcher_defers_hostname_selection_to_glab_by_default(self):
        calls = []

        def runner(command, **kwargs):
            calls.append(command)
            return subprocess.CompletedProcess(command, 0, "", "")

        attention_inbox.fetch_gitlab_todos(runner=runner)

        self.assertNotIn("--hostname", calls[0])

    def test_fetcher_reports_glab_errors(self):
        def runner(command, **kwargs):
            return subprocess.CompletedProcess(
                command, 1, "", "authentication required"
            )

        with self.assertRaisesRegex(
            attention_inbox.InboxError, "authentication required"
        ):
            attention_inbox.fetch_gitlab_todos(runner=runner)

    def test_fetcher_rejects_invalid_json(self):
        def runner(command, **kwargs):
            return subprocess.CompletedProcess(command, 0, "not-json\n", "")

        with self.assertRaisesRegex(attention_inbox.InboxError, "invalid JSON"):
            attention_inbox.fetch_gitlab_todos(runner=runner)

    def test_normalizes_gitlab_fields_into_provider_neutral_item(self):
        item = attention_inbox.normalize_gitlab_todo(
            gitlab_todo(7, action="approval_required")
        )

        self.assertEqual(
            item,
            {
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
            },
        )

    def test_collects_newest_items_first(self):
        todos = [
            gitlab_todo(1, updated_at="2026-07-16T12:00:00Z"),
            gitlab_todo(2, updated_at="2026-07-16T13:00:00Z"),
        ]

        items = attention_inbox.collect_inbox(fetcher=lambda hostname: todos)

        self.assertEqual([item["source_id"] for item in items], [2, 1])

    def test_renders_human_readable_inbox(self):
        item = attention_inbox.normalize_gitlab_todo(
            gitlab_todo(7, action="build_failed")
        )

        output = attention_inbox.render_text([item])

        self.assertIn("1 pending item:", output)
        self.assertIn(
            "[gitlab] Build failed · tools/widget!42 · Review the change",
            output,
        )
        self.assertIn(item["url"], output)

    def test_renders_empty_inbox(self):
        self.assertEqual(attention_inbox.render_text([]), "No pending items.\n")

    def test_json_document_has_versioned_summary(self):
        item = attention_inbox.normalize_gitlab_todo(gitlab_todo(7))

        document = attention_inbox.build_document([item])

        self.assertEqual(document["schema_version"], 1)
        self.assertEqual(document["summary"], {"total": 1, "by_source": {"gitlab": 1}})
        self.assertEqual(document["items"], [item])

    def test_main_emits_json(self):
        item = attention_inbox.normalize_gitlab_todo(gitlab_todo(7))
        stdout = io.StringIO()
        with (
            mock.patch.object(
                attention_inbox, "collect_inbox", return_value=[item]
            ) as collect,
            contextlib.redirect_stdout(stdout),
        ):
            result = attention_inbox.main(
                ["--format=JSON", "--gitlab-hostname=gitlab.example.com"]
            )

        self.assertEqual(result, 0)
        self.assertEqual(json.loads(stdout.getvalue())["items"], [item])
        collect.assert_called_once_with(hostname="gitlab.example.com")

    def test_main_reports_collection_errors(self):
        stderr = io.StringIO()
        with (
            mock.patch.object(
                attention_inbox,
                "collect_inbox",
                side_effect=attention_inbox.InboxError("not authenticated"),
            ),
            contextlib.redirect_stderr(stderr),
        ):
            result = attention_inbox.main([])

        self.assertEqual(result, 1)
        self.assertEqual(stderr.getvalue(), "attention-inbox: not authenticated\n")


if __name__ == "__main__":
    unittest.main()
