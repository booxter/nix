from __future__ import annotations

from copy import deepcopy
from pathlib import Path

from atomic_file_writes import write_text_atomic
from deepmerge.merger import Merger
from pydantic import JsonValue, RootModel


class Settings(RootModel[dict[str, JsonValue]]):
    pass


MERGER = Merger(
    [(dict, ["merge"])],
    ["override"],
    ["override"],
)


def read_settings(path: Path) -> Settings:
    return Settings.model_validate_json(path.read_text(encoding="utf-8"))


def merge_settings(current: Settings, desired: Settings) -> Settings:
    merged = MERGER.merge(deepcopy(current.root), desired.root)
    return Settings.model_validate(merged)


def reconcile(target: Path, desired_path: Path) -> Settings:
    try:
        current = read_settings(target)
    except FileNotFoundError:
        current = Settings(root={})
    merged = merge_settings(current, read_settings(desired_path))
    write_text_atomic(target, merged.model_dump_json(indent=2) + "\n", mode=0o600)
    return merged
