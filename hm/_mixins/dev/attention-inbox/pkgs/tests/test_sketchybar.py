import io
import os
import shlex
import time
from collections.abc import Iterator, Sequence
from contextlib import contextmanager

import pytest

from attention_inbox.errors import InboxError
from attention_inbox.model import Author, InboxItem
from attention_inbox.service import InboxService
from attention_inbox.sketchybar import (
    Config,
    item_is_new,
    local_week_start_epoch,
    main,
    popup_click_script,
    update,
)
from fakes import FakeSource, RecordingSketchybar

NOW = 1_784_203_200


def inbox_item(
    index: int,
    *,
    created_at: str = "2026-07-01T12:00:00Z",
    title: str | None = None,
    url: str | None = None,
) -> InboxItem:
    return InboxItem(
        id=f"gitlab:{index}",
        source="gitlab",
        source_id=index,
        kind="merge_request",
        reason="approval_required" if index == 0 else "assigned",
        context="tools/widget",
        reference=f"!{index}",
        title=title or f"Item {index}",
        body=None,
        url=url,
        author=Author(name=None, username=None),
        created_at=created_at,
        updated_at=created_at,
    )


def config() -> Config:
    return Config.from_environment({"SKETCHYBAR_BIN": "/nix/store/sketchybar/bin/sketchybar"})


def properties(arguments: Sequence[str]) -> dict[str, dict[str, str]]:
    result: dict[str, dict[str, str]] = {}
    current: str | None = None
    iterator = iter(arguments)
    for argument in iterator:
        if argument == "--set":
            current = next(iterator)
            result.setdefault(current, {})
        elif current is not None:
            name, separator, value = argument.partition("=")
            assert separator == "=", argument
            result[current][name] = value
    return result


def render(items: list[InboxItem]) -> tuple[dict[str, dict[str, str]], RecordingSketchybar]:
    bar = RecordingSketchybar()
    update(config(), InboxService(FakeSource(items=items)), bar, now=NOW)
    rendered: dict[str, dict[str, str]] = {}
    for call in bar.calls:
        rendered.update(properties(call))
    return rendered, bar


def test_hides_empty_inbox_and_all_popup_rows() -> None:
    rendered, _ = render([])
    assert rendered["attention.inbox"] == {
        "drawing": "off",
        "popup.drawing": "off",
    }
    for index in range(10):
        assert rendered[f"attention.inbox.{index}"] == {
            "drawing": "off",
            "click_script": "",
        }


def test_renders_old_and_new_items() -> None:
    rendered, _ = render(
        [
            inbox_item(
                0,
                created_at="2026-07-14T08:00:00.123Z",
                title="Review\nthis week",
            ),
            inbox_item(1, created_at="2026-07-12T08:00:00Z"),
        ]
    )
    assert rendered["attention.inbox"] == {
        "drawing": "on",
        "label": "2",
        "label.color": "0xfffe8019",
        "icon.drawing": "on",
        "icon": "●",
        "icon.color": "0xfffabd2f",
    }
    assert rendered["attention.inbox.0"]["label"] == (
        "gitlab · approval required · tools/widget!0 · Review this week"
    )
    assert rendered["attention.inbox.0"]["icon.drawing"] == "on"
    assert rendered["attention.inbox.0"]["label.padding_left"] == "4"
    assert rendered["attention.inbox.1"]["icon.drawing"] == "off"
    assert rendered["attention.inbox.1"]["label.padding_left"] == "8"


@contextmanager
def timezone(value: str) -> Iterator[None]:
    previous = os.environ.get("TZ")
    os.environ["TZ"] = value
    time.tzset()
    try:
        yield
    finally:
        if previous is None:
            os.environ.pop("TZ", None)
        else:
            os.environ["TZ"] = previous
        time.tzset()


def test_uses_local_calendar_week_near_utc_boundary() -> None:
    with timezone("EST5EDT,M3.2.0,M11.1.0"):
        start = local_week_start_epoch(1_783_904_400)
    assert item_is_new(inbox_item(0, created_at="2026-07-12T23:00:00Z"), start)


@pytest.mark.parametrize(
    ("count", "color"),
    [(10, "0xfffe8019"), (11, "0xfffb4934")],
)
def test_limits_popup_to_ten_items_and_colors_overflow(
    count: int,
    color: str,
) -> None:
    rendered, _ = render([inbox_item(index) for index in range(count)])
    assert rendered["attention.inbox"]["label"] == str(count)
    assert rendered["attention.inbox"]["label.color"] == color
    assert rendered["attention.inbox.9"]["label"].endswith("Item 9")
    assert "attention.inbox.10" not in rendered


def test_popup_click_script_preserves_url_as_one_argument() -> None:
    url = "https://gitlab.test/item?tab=notes&next='; touch /tmp/nope"
    lexer = shlex.shlex(
        popup_click_script(config(), url),
        posix=True,
        punctuation_chars=";",
    )
    lexer.whitespace_split = True
    arguments = list(lexer)
    assert arguments == [
        "/usr/bin/open",
        url,
        ";",
        "/nix/store/sketchybar/bin/sketchybar",
        "--set",
        "attention.inbox",
        "popup.drawing=off",
    ]


def test_collection_failure_shows_error_and_hides_rows() -> None:
    bar = RecordingSketchybar()
    source = FakeSource(error=InboxError("not authenticated"))
    update(config(), InboxService(source), bar, now=NOW)
    assert properties(bar.calls[0])["attention.inbox"] == {
        "drawing": "on",
        "popup.drawing": "off",
        "icon.drawing": "on",
        "icon": "!",
        "icon.color": "0xfffabd2f",
        "label": "?",
        "label.color": "0xfffabd2f",
    }
    hidden = properties(bar.calls[1])
    assert all(hidden[f"attention.inbox.{index}"]["drawing"] == "off" for index in range(10))


def test_main_reads_hostname_and_custom_colors() -> None:
    source = FakeSource(items=[inbox_item(0)])
    bar = RecordingSketchybar()
    status = main(
        service=InboxService(source),
        bar=bar,
        now=NOW,
        environment={
            "SKETCHYBAR_BIN": "/nix/store/sketchybar/bin/sketchybar",
            "ATTENTION_INBOX_GITLAB_HOSTNAME": "gitlab.example.com",
            "SKETCHYBAR_COLOR_ORANGE": "0xff123456",
        },
    )
    assert status == 0
    assert source.hostnames == ["gitlab.example.com"]
    assert properties(bar.calls[0])["attention.inbox"]["label.color"] == "0xff123456"


def test_main_reports_configuration_and_sketchybar_failures() -> None:
    stderr = io.StringIO()
    assert main(environment={}, stderr=stderr) == 1
    assert "missing environment setting SKETCHYBAR_BIN" in stderr.getvalue()

    stderr = io.StringIO()
    bar = RecordingSketchybar(error=InboxError("SketchyBar unavailable"))
    assert (
        main(
            service=InboxService(FakeSource()),
            bar=bar,
            environment={"SKETCHYBAR_BIN": "x"},
            stderr=stderr,
        )
        == 1
    )
    assert stderr.getvalue() == "attention-inbox-sketchybar: SketchyBar unavailable\n"
