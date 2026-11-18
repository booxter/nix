"""Select startup defaults before replacing this process with the real Codex CLI."""

import json
import os
import subprocess
import sys
from collections.abc import Sequence
from dataclasses import dataclass
from typing import Protocol

from pydantic import BaseModel, ValidationError


class Model(BaseModel):
    slug: str


class Catalog(BaseModel):
    models: list[Model]


@dataclass(frozen=True)
class Preference:
    model: str
    effort: str


class Runtime(Protocol):
    def catalog(self) -> Catalog | None: ...

    def launch(self, arguments: Sequence[str]) -> None: ...


@dataclass(frozen=True)
class CodexRuntime:
    command: tuple[str, ...]
    timeout: float = 5

    def catalog(self) -> Catalog | None:
        try:
            result = subprocess.run(
                [*self.command, "debug", "models"],
                capture_output=True,
                check=True,
                timeout=self.timeout,
            )
            return Catalog.model_validate_json(result.stdout)
        except (OSError, subprocess.SubprocessError, ValidationError):
            return None

    def launch(self, arguments: Sequence[str]) -> None:
        os.execv(self.command[0], [*self.command, *arguments])


def has_explicit_settings(arguments: Sequence[str]) -> bool:
    """Preserve deliberate settings without interpreting Codex's command structure."""
    explicit_options = {
        "--model",
        "--config",
        "--profile",
        "--remote",
        "--oss",
        "--local-provider",
        "--help",
        "--version",
        "-h",
        "-V",
    }
    for argument in arguments:
        if argument == "--":
            break
        option = argument.split("=", 1)[0]
        if option in explicit_options or argument.startswith(("-m", "-c", "-p")):
            return True
    return False


def launch(arguments: Sequence[str], preference: Preference, runtime: Runtime) -> None:
    if has_explicit_settings(arguments):
        runtime.launch(arguments)
        return

    catalog = runtime.catalog()
    if catalog is not None and any(model.slug == preference.model for model in catalog.models):
        runtime.launch(
            [
                # Global config overrides work across subcommands; Codex owns their routing.
                "-c",
                f"model={json.dumps(preference.model)}",
                "-c",
                f"model_reasoning_effort={json.dumps(preference.effort)}",
                *arguments,
            ]
        )
    else:
        print("codex: preferred model unavailable; using configured defaults", file=sys.stderr)
        runtime.launch(arguments)


def main() -> None:
    # The Nix wrapper supplies these three fixed arguments before the user's arguments.
    executable, model, effort, *arguments = sys.argv[1:]
    launch(arguments, Preference(model, effort), CodexRuntime((executable,)))
