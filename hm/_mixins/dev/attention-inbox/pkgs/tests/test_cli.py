import io
import json

from attention_inbox.cli import main
from attention_inbox.errors import InboxError
from attention_inbox.gitlab import normalize_gitlab_todo
from attention_inbox.service import InboxService
from fakes import FakeSource, gitlab_todo


def test_main_emits_json() -> None:
    stdout = io.StringIO()
    source = FakeSource(items=[normalize_gitlab_todo(gitlab_todo(7))])
    result = main(
        ["--format=JSON", "--gitlab-hostname=gitlab.example.com"],
        service=InboxService(source),
        stdout=stdout,
    )
    assert result == 0
    assert json.loads(stdout.getvalue())["items"][0]["id"] == "gitlab:7"
    assert source.hostnames == ["gitlab.example.com"]


def test_main_reports_collection_errors() -> None:
    stderr = io.StringIO()
    result = main(
        [],
        service=InboxService(FakeSource(error=InboxError("not authenticated"))),
        stderr=stderr,
    )
    assert result == 1
    assert stderr.getvalue() == "attention-inbox: not authenticated\n"
