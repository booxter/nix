from __future__ import annotations

from pathlib import Path

import pytest
from pydantic import ValidationError

from degoog_settings.cli import run
from degoog_settings.settings import Settings, read_settings, reconcile


def write_settings(path: Path, settings: Settings) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(settings.model_dump_json(indent=2) + "\n", encoding="utf-8")


def test_reconcile_recursively_overlays_managed_settings(tmp_path: Path) -> None:
    target = tmp_path / "state" / "settings.json"
    desired = tmp_path / "secret.json"
    write_settings(
        target,
        Settings(
            root={
                "plugin": {"kept": True, "overridden": "old"},
                "local": {"enabled": True},
                "list": ["old"],
            }
        ),
    )
    write_settings(
        desired,
        Settings(root={"plugin": {"overridden": "new", "added": 1}, "list": ["new"]}),
    )

    merged = reconcile(target, desired)

    assert merged.root == {
        "plugin": {"kept": True, "overridden": "new", "added": 1},
        "local": {"enabled": True},
        "list": ["new"],
    }
    assert read_settings(target) == merged
    assert target.stat().st_mode & 0o777 == 0o600


def test_reconcile_creates_missing_target(tmp_path: Path) -> None:
    target = tmp_path / "state" / "settings.json"
    desired = tmp_path / "secret.json"
    write_settings(desired, Settings(root={"plugin": {"token": "secret"}}))

    run(["--target", str(target), "--desired", str(desired)])

    assert read_settings(target).root == {"plugin": {"token": "secret"}}


@pytest.mark.parametrize("content", ["[]", '"scalar"', "not json"])
def test_reconcile_rejects_non_object_or_invalid_json(tmp_path: Path, content: str) -> None:
    target = tmp_path / "settings.json"
    desired = tmp_path / "secret.json"
    target.write_text("{}", encoding="utf-8")
    desired.write_text(content, encoding="utf-8")

    with pytest.raises(ValidationError):
        reconcile(target, desired)

    assert read_settings(target).root == {}
