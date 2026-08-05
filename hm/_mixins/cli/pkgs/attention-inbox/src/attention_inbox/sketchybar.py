from __future__ import annotations

import datetime as dt
import os
import re
import shlex
import subprocess
import sys
import time
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from typing import Protocol, TextIO

from attention_inbox.errors import InboxError
from attention_inbox.model import InboxItem
from attention_inbox.service import InboxService, default_service

ITEM = "attention.inbox"
POPUP_ITEM_PREFIX = "attention.inbox."
MAX_ITEMS = 10
DEFAULT_NEUTRAL = "0xffd5c4a1"
DEFAULT_ORANGE = "0xfffe8019"
DEFAULT_RED = "0xfffb4934"
DEFAULT_YELLOW = "0xfffabd2f"


@dataclass(frozen=True)
class Config:
    gitlab_hostname: str | None
    neutral: str
    orange: str
    red: str
    yellow: str
    sketchybar_executable: str

    @classmethod
    def from_environment(cls, environment: Mapping[str, str]) -> Config:
        executable = environment.get("SKETCHYBAR_BIN", "")
        if not executable:
            raise InboxError("missing environment setting SKETCHYBAR_BIN")
        return cls(
            gitlab_hostname=environment.get("ATTENTION_INBOX_GITLAB_HOSTNAME") or None,
            neutral=environment.get("SKETCHYBAR_COLOR_NEUTRAL", DEFAULT_NEUTRAL),
            orange=environment.get("SKETCHYBAR_COLOR_ORANGE", DEFAULT_ORANGE),
            red=environment.get("SKETCHYBAR_COLOR_RED", DEFAULT_RED),
            yellow=environment.get("SKETCHYBAR_COLOR_YELLOW", DEFAULT_YELLOW),
            sketchybar_executable=executable,
        )


class Sketchybar(Protocol):
    def run(self, arguments: Sequence[str]) -> None: ...


@dataclass(frozen=True)
class SketchybarCommand:
    executable: str

    def run(self, arguments: Sequence[str]) -> None:
        result = subprocess.run(
            [self.executable, *arguments],
            check=False,
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            detail = result.stderr.strip()
            message = f"sketchybar exited with status {result.returncode}"
            if detail:
                message += f": {detail}"
            raise InboxError(message)


@dataclass(frozen=True)
class PopupRow:
    label: str
    url: str | None
    is_new: bool


def local_week_start_epoch(now: float) -> float:
    local = time.localtime(now)
    monday = dt.date(local.tm_year, local.tm_mon, local.tm_mday) - dt.timedelta(days=local.tm_wday)
    return time.mktime((monday.year, monday.month, monday.day, 0, 0, 0, -1, -1, -1))


def item_is_new(item: InboxItem, week_start: float) -> bool:
    if item.created_at is None:
        return False
    try:
        created = dt.datetime.fromisoformat(item.created_at.replace("Z", "+00:00"))
    except ValueError:
        return False
    if created.tzinfo is None:
        return False
    return created.timestamp() >= week_start


def clean(value: str) -> str:
    return re.sub(r"[\r\n\t]+", " ", value)


def popup_label(item: InboxItem) -> str:
    location = clean((item.context or "") + (item.reference or ""))
    fields = [
        clean(item.source or "unknown"),
        clean(item.reason or "item").replace("_", " "),
        location,
        clean(item.title or "Untitled item"),
    ]
    label = " · ".join(field for field in fields if field)
    return label if len(label) <= 100 else label[:99] + "…"


def popup_click_script(config: Config, url: str) -> str:
    # SketchyBar click_script is necessarily shell text; quote every dynamic argument.
    open_command = shlex.join(["/usr/bin/open", url])
    hide_command = shlex.join([config.sketchybar_executable, "--set", ITEM, "popup.drawing=off"])
    return f"{open_command}; {hide_command}"


def hide_popup_items(bar: Sketchybar) -> None:
    arguments: list[str] = []
    for index in range(MAX_ITEMS):
        arguments.extend(["--set", f"{POPUP_ITEM_PREFIX}{index}", "drawing=off", "click_script="])
    bar.run(arguments)


def hide_inbox(bar: Sketchybar) -> None:
    bar.run(["--set", ITEM, "drawing=off", "popup.drawing=off"])
    hide_popup_items(bar)


def show_error(config: Config, bar: Sketchybar) -> None:
    bar.run(
        [
            "--set",
            ITEM,
            "drawing=on",
            "popup.drawing=off",
            "icon.drawing=on",
            "icon=!",
            f"icon.color={config.yellow}",
            "label=?",
            f"label.color={config.yellow}",
        ]
    )
    hide_popup_items(bar)


def update(
    config: Config,
    service: InboxService,
    bar: Sketchybar,
    *,
    now: float,
) -> None:
    try:
        items = service.collect(config.gitlab_hostname)
    except InboxError:
        show_error(config, bar)
        return
    if not items:
        hide_inbox(bar)
        return

    week_start = local_week_start_epoch(now)
    rows = [
        PopupRow(
            label=popup_label(item),
            url=item.url,
            is_new=item_is_new(item, week_start),
        )
        for item in items[:MAX_ITEMS]
    ]
    new_count = sum(item_is_new(item, week_start) for item in items)
    count_color = config.red if len(items) > MAX_ITEMS else config.orange
    arguments = [
        "--set",
        ITEM,
        "drawing=on",
        f"label={len(items)}",
        f"label.color={count_color}",
    ]
    if new_count:
        arguments.extend(["icon.drawing=on", "icon=●", f"icon.color={config.yellow}"])
    else:
        arguments.append("icon.drawing=off")

    for index in range(MAX_ITEMS):
        arguments.extend(["--set", f"{POPUP_ITEM_PREFIX}{index}"])
        if index >= len(rows):
            arguments.extend(["drawing=off", "click_script="])
            continue
        row = rows[index]
        click_script = popup_click_script(config, row.url) if row.url is not None else ""
        arguments.extend(
            [
                "drawing=on",
                f"label={row.label}",
                f"label.color={config.neutral}",
                f"click_script={click_script}",
            ]
        )
        if row.is_new:
            arguments.extend(
                [
                    "icon.drawing=on",
                    "icon=●",
                    f"icon.color={config.yellow}",
                    "label.padding_left=4",
                ]
            )
        else:
            arguments.extend(["icon.drawing=off", "label.padding_left=8"])
    bar.run(arguments)


def main(
    _argv: Sequence[str] | None = None,
    *,
    service: InboxService | None = None,
    bar: Sketchybar | None = None,
    now: float | None = None,
    environment: Mapping[str, str] | None = None,
    stderr: TextIO = sys.stderr,
) -> int:
    try:
        config = Config.from_environment(os.environ if environment is None else environment)
        update(
            config,
            service or default_service(),
            bar or SketchybarCommand(config.sketchybar_executable),
            now=time.time() if now is None else now,
        )
    except InboxError as error:
        print(f"attention-inbox-sketchybar: {error}", file=stderr)
        return 1
    return 0
