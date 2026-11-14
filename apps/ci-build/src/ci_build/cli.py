from __future__ import annotations

import argparse
import os
import subprocess
import sys
import tempfile
from collections.abc import Sequence
from pathlib import Path
from typing import Annotated, Protocol

from pydantic import BaseModel, RootModel, StringConstraints, ValidationError

StorePath = Annotated[str, StringConstraints(pattern=r"^/nix/store/[a-z0-9]{32}-[^/\s]+$")]


class BuildResult(BaseModel):
    outputs: dict[str, StorePath]


class BuildResults(RootModel[list[BuildResult]]):
    pass


class Commands(Protocol):
    def capture(self, arguments: Sequence[str]) -> str: ...

    def run(self, arguments: Sequence[str]) -> None: ...


class NativeCommands:
    def capture(self, arguments: Sequence[str]) -> str:
        return subprocess.run(arguments, check=True, text=True, stdout=subprocess.PIPE).stdout

    def run(self, arguments: Sequence[str]) -> None:
        subprocess.run(arguments, check=True)


def build_and_publish(targets: Sequence[str], config: Path, commands: Commands) -> None:
    # Keep outputs rooted until Attic has finished reading their closures.
    with tempfile.TemporaryDirectory(prefix="ci-build-") as directory:
        result = commands.capture(
            [
                "nix",
                "build",
                "--json",
                "--out-link",
                str(Path(directory) / "result"),
                "--keep-going",
                "-L",
                "--show-trace",
                *targets,
            ]
        )
        publish_outputs(result, config, commands)


def publish_outputs(result: str, config: Path, commands: Commands) -> None:
    results = BuildResults.model_validate_json(result)
    # Use Nix's requested output set, never store changes: other users build concurrently.
    paths = sorted({path for build in results.root for path in build.outputs.values()})
    if not paths:
        raise ValueError("Nix returned no build outputs to publish")

    # Attic includes each output's closure, even when Nix reused an existing result.
    commands.run(["attic", "--config", str(config), "push", "ci:github", *paths])


def main(
    argv: Sequence[str] | None = None,
    *,
    commands: Commands | None = None,
    config_file: str | None = None,
) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("targets", nargs="+")
    args = parser.parse_args(argv)
    config_file = config_file or os.environ.get("CI_ATTIC_CONFIG")
    if not config_file or not Path(config_file).is_file():
        print("ci-build: CI_ATTIC_CONFIG must point to the runner's Attic config", file=sys.stderr)
        return 1

    try:
        build_and_publish(args.targets, Path(config_file), commands or NativeCommands())
    except subprocess.CalledProcessError as error:
        return error.returncode if error.returncode > 0 else 1
    except (OSError, ValidationError, ValueError) as error:
        print(f"ci-build: {error}", file=sys.stderr)
        return 1
    return 0
