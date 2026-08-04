from __future__ import annotations

import os
import sys
from collections.abc import Mapping, Sequence
from pathlib import Path

from .errors import RotationError


def response(prompt: str, environment: Mapping[str, str]) -> str:
    normalized = prompt.casefold()
    if "username" in normalized:
        return "x-access-token"
    if "password" not in normalized:
        return ""
    configured = environment.get("PKI_ROTATION_GITHUB_TOKEN_FILE")
    if not configured:
        raise RotationError("PKI_ROTATION_GITHUB_TOKEN_FILE is not configured")
    token_file = Path(configured)
    token = token_file.read_text().strip()
    if not token:
        raise RotationError(f"GitHub token file is empty: {token_file}")
    return token


def main(argv: Sequence[str] | None = None) -> int:
    arguments = tuple(argv if argv is not None else sys.argv[1:])
    prompt = arguments[0] if arguments else ""
    try:
        print(response(prompt, os.environ))
    except (OSError, RotationError) as error:
        raise SystemExit(str(error)) from error
    return 0
