from collections.abc import Sequence
from dataclasses import dataclass, field

from sketchybar_applet import SketchybarError

ENVIRONMENT = {
    "SKETCHYBAR_BIN": "sketchybar",
    "SKETCHYBAR_COLOR_GREEN": "green",
    "SKETCHYBAR_COLOR_RED": "red",
    "SKETCHYBAR_COLOR_BLUE": "blue",
    "SKETCHYBAR_COLOR_NEUTRAL": "neutral",
}


@dataclass
class RecordingSketchybar:
    calls: list[list[str]] = field(default_factory=list)
    error: str | None = None

    def run(self, arguments: Sequence[str]) -> None:
        if self.error is not None:
            raise SketchybarError(self.error)
        self.calls.append(list(arguments))


def labels(bar: RecordingSketchybar) -> dict[str, tuple[str, str]]:
    """Map each item to its label and color from the last update."""
    [arguments] = bar.calls
    items: dict[str, tuple[str, str]] = {}
    item = ""
    settings: dict[str, str] = {}
    for argument in [*arguments, "--set"]:
        if argument == "--set":
            if item:
                items[item] = (settings.get("label", ""), settings.get("label.color", ""))
            item = ""
            settings = {}
        elif not item:
            item = argument
        else:
            key, _, value = argument.partition("=")
            settings[key] = value
    return items
