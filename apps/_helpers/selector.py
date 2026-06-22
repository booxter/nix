#!/usr/bin/env python3
import argparse
import asyncio
import math
import shutil
import sys
from pathlib import Path
import selectors

from prompt_toolkit.application import Application
from prompt_toolkit.formatted_text import FormattedText
from prompt_toolkit.input.defaults import create_input
from prompt_toolkit.key_binding import KeyBindings
from prompt_toolkit.layout import HSplit, Layout, Window
from prompt_toolkit.layout.controls import FormattedTextControl
from prompt_toolkit.output.defaults import create_output
from prompt_toolkit.styles import Style


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--file", type=Path, default=None)
    args = parser.parse_args()

    if args.file:
        items = [
            line.strip() for line in args.file.read_text().splitlines() if line.strip()
        ]
    else:
        items = [line.strip() for line in sys.stdin if line.strip()]
    if not items:
        return 1

    cols = 2
    rows = math.ceil(len(items) / cols)
    selected = set()
    cursor = 0

    def render() -> FormattedText:
        width = shutil.get_terminal_size((80, 20)).columns
        col_width = max(20, (width - (cols - 1) * 3) // cols)
        lines = []
        for r in range(rows):
            line_parts = []
            for c in range(cols):
                i = r + c * rows
                if i >= len(items):
                    continue
                name = items[i]
                mark = "[x]" if i in selected else "[ ]"
                text = f"{mark} {name}"
                style = "class:item"
                if i in selected:
                    style = "class:selected"
                if i == cursor:
                    style = f"{style} class:cursor"
                line_parts.append((style, text.ljust(col_width)))
                if c < cols - 1:
                    line_parts.append(("", "   "))
            lines.extend(line_parts)
            lines.append(("", "\n"))
        return FormattedText(lines)

    kb = KeyBindings()

    @kb.add("left")
    def _left(event) -> None:
        nonlocal cursor
        if cursor - rows >= 0:
            cursor -= rows

    @kb.add("right")
    def _right(event) -> None:
        nonlocal cursor
        if cursor + rows < len(items):
            cursor += rows

    @kb.add("up")
    def _up(event) -> None:
        nonlocal cursor
        if cursor % rows > 0:
            cursor -= 1

    @kb.add("down")
    def _down(event) -> None:
        nonlocal cursor
        if cursor % rows < rows - 1 and cursor + 1 < len(items):
            cursor += 1

    @kb.add(" ")
    def _toggle(event) -> None:
        if cursor in selected:
            selected.remove(cursor)
        else:
            selected.add(cursor)

    @kb.add("enter")
    def _enter(event) -> None:
        if not selected:
            selected.add(cursor)
        event.app.exit(result=True)

    @kb.add("escape")
    @kb.add("q")
    def _exit(event) -> None:
        event.app.exit(result=False)

    root_container = HSplit(
        [
            Window(
                FormattedTextControl(render),
                height=rows + 1,
                always_hide_cursor=True,
            )
        ]
    )
    style = Style.from_dict(
        {
            "cursor": "reverse",
            "item": "",
            "selected": "fg:ansigreen",
        }
    )
    try:
        tty_in = open("/dev/tty", "r", encoding="utf-8", buffering=1)
        tty_out = open("/dev/tty", "w", encoding="utf-8", buffering=1)
    except OSError as exc:
        print(f"selector: failed to open /dev/tty: {exc}", file=sys.stderr)
        return 1

    app = Application(
        layout=Layout(root_container),
        key_bindings=kb,
        style=style,
        full_screen=True,
        input=create_input(stdin=tty_in, always_prefer_tty=False),
        output=create_output(stdout=tty_out, always_prefer_tty=False),
    )
    loop = asyncio.SelectorEventLoop(selectors.SelectSelector())
    asyncio.set_event_loop(loop)
    try:
        ok = loop.run_until_complete(app.run_async())
    finally:
        loop.close()
        tty_in.close()
        tty_out.close()
    if not ok or not selected:
        return 1

    for i in sorted(selected):
        print(items[i])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
