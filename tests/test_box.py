import importlib.util
import subprocess
import sys
import textwrap
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BOX_PATH = ROOT / "scripts" / "_helpers" / "box.py"


def load_box_module():
    spec = importlib.util.spec_from_file_location("box", BOX_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def run_box(input_text: str, *args: str) -> str:
    result = subprocess.run(
        [sys.executable, str(BOX_PATH), *args],
        input=input_text,
        text=True,
        capture_output=True,
        check=True,
    )
    return result.stdout


def expected_box(ascii_box: str, style: str = "single") -> str:
    lines = [
        line.rstrip("\n")
        for line in textwrap.dedent(ascii_box).strip("\n").splitlines()
    ]
    if not lines:
        return "\n"
    if style == "double":
        tl, tr, bl, br, h, v = "╔", "╗", "╚", "╝", "═", "║"
    else:
        tl, tr, bl, br, h, v = "┌", "┐", "└", "┘", "─", "│"

    out = []
    for idx, line in enumerate(lines):
        if len(line) < 2:
            out.append(line)
            continue
        if idx == 0:
            mid = line[1:-1].replace("-", h)
            out.append(tl + mid + tr)
        elif idx == len(lines) - 1:
            mid = line[1:-1].replace("-", h)
            out.append(bl + mid + br)
        else:
            mid = line[1:-1]
            out.append(v + mid + v)
    return "\n".join(out) + "\n"


def test_parse_margin_single_value():
    box = load_box_module()
    assert box.parse_margin("2") == (2, 2)


def test_parse_margin_pair():
    box = load_box_module()
    assert box.parse_margin("1 3") == (1, 3)


def test_parse_margin_invalid():
    box = load_box_module()
    try:
        box.parse_margin("1 2 3")
    except ValueError as exc:
        assert "margin/padding" in str(exc)
    else:
        raise AssertionError("Expected ValueError for invalid margin")


def test_basic_box_output():
    output = run_box(
        "hi\n", "--border", "single", "--padding", "0 0", "--margin", "0 0"
    )
    assert output == expected_box(
        """
    +--+
    |hi|
    +--+
    """
    )


def test_center_alignment():
    output = run_box(
        "hi\n",
        "--border",
        "single",
        "--padding",
        "0 0",
        "--margin",
        "0 0",
        "--width",
        "6",
        "--align",
        "center",
    )
    assert output == expected_box(
        """
    +----+
    | hi |
    +----+
    """
    )


def test_truncation():
    output = run_box(
        "abcd\n",
        "--border",
        "single",
        "--padding",
        "0 0",
        "--margin",
        "0 0",
        "--width",
        "4",
    )
    assert output == expected_box(
        """
    +--+
    |ab|
    +--+
    """
    )
