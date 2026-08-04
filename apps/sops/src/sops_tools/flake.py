from __future__ import annotations

import json
from pathlib import Path

from .errors import ToolError
from .process import ProcessRunner


def archive_flake_source(runner: ProcessRunner, repo_root: Path) -> Path:
    output = runner.run(["nix", "flake", "archive", "--json", f"path:{repo_root}"])
    try:
        payload: object = json.loads(output)
    except json.JSONDecodeError as error:
        raise ToolError(f"failed to archive flake source: {error}") from error
    if not isinstance(payload, dict):
        raise ToolError("failed to archive flake source")
    path = payload.get("path")
    if not isinstance(path, str) or not path.startswith("/nix/store/"):
        raise ToolError("failed to archive flake source")
    return Path(path)
