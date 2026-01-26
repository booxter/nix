#!/usr/bin/env python3
import argparse
import sys

DOUBLE = {
    "tl": "╔",
    "tr": "╗",
    "bl": "╚",
    "br": "╝",
    "h": "═",
    "v": "║",
}
SINGLE = {
    "tl": "┌",
    "tr": "┐",
    "bl": "└",
    "br": "┘",
    "h": "─",
    "v": "│",
}


def parse_margin(value: str) -> tuple[int, int]:
    parts = value.split()
    if len(parts) == 1:
        return int(parts[0]), int(parts[0])
    if len(parts) == 2:
        return int(parts[0]), int(parts[1])
    raise ValueError("margin/padding must be 1 or 2 integers")


def colorize(text: str, color: int | None) -> str:
    if color is None:
        return text
    return f"\033[38;5;{color}m{text}\033[0m"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--border", choices=["single", "double"], default="single")
    parser.add_argument("--width", type=int, default=0)
    parser.add_argument("--max-width", type=int, default=79)
    parser.add_argument("--align", choices=["left", "center"], default="left")
    parser.add_argument("--margin", default="0 0")
    parser.add_argument("--padding", default="0 0")
    parser.add_argument("--border-color", type=int, default=None)
    parser.add_argument("--text-color", type=int, default=None)
    args = parser.parse_args()

    margin_v, margin_h = parse_margin(args.margin)
    pad_v, pad_h = parse_margin(args.padding)
    lines = [line.rstrip("\n") for line in sys.stdin.read().splitlines()]

    if args.width > 0:
        width = args.width
    else:
        max_line = max((len(line) for line in lines), default=0)
        width = max_line + 2 + pad_h * 2
    width = max(1, min(width, args.max_width))
    inner_width = width - 2 - pad_h * 2

    box_chars = DOUBLE if args.border == "double" else SINGLE
    top = box_chars["tl"] + box_chars["h"] * (width - 2) + box_chars["tr"]
    bottom = box_chars["bl"] + box_chars["h"] * (width - 2) + box_chars["br"]
    top = colorize(top, args.border_color)
    bottom = colorize(bottom, args.border_color)

    def format_line(text: str) -> str:
        if len(text) > inner_width:
            text = text[:inner_width]
        if args.align == "center":
            pad_left = max(0, (inner_width - len(text)) // 2)
            pad_right = inner_width - len(text) - pad_left
        else:
            pad_left = 0
            pad_right = inner_width - len(text)
        content = " " * pad_h + " " * pad_left + text + " " * pad_right + " " * pad_h
        return (
            colorize(box_chars["v"], args.border_color)
            + colorize(content, args.text_color)
            + colorize(box_chars["v"], args.border_color)
        )

    out_lines = []
    out_lines.extend([""] * margin_v)
    out_lines.append(" " * margin_h + top)
    for _ in range(pad_v):
        out_lines.append(" " * margin_h + format_line(""))
    for line in lines:
        out_lines.append(" " * margin_h + format_line(line))
    for _ in range(pad_v):
        out_lines.append(" " * margin_h + format_line(""))
    out_lines.append(" " * margin_h + bottom)
    out_lines.extend([""] * margin_v)

    sys.stdout.write("\n".join(out_lines) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
