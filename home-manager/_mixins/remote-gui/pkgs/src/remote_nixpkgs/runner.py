import re
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from pathlib import PurePosixPath
from typing import NoReturn, TextIO
from urllib.parse import urlparse

from remote_nixpkgs.runtime import RemoteSession, RunError


@dataclass(frozen=True)
class RunOptions:
    flake_ref: str
    package_attribute: str
    command: str | None
    allow_unfree: bool
    program_arguments: tuple[str, ...]

    @property
    def installable(self) -> str:
        return f"{self.flake_ref}#{self.package_attribute}"


def normalize_flake_ref(source: str) -> str:
    pull_request = re.fullmatch(r"#?(\d+)", source)
    if pull_request is not None:
        return f"github:NixOS/nixpkgs?ref=pull/{pull_request.group(1)}/head"

    candidate = source if "://" in source else f"https://{source}"
    parsed = urlparse(candidate)
    parts = parsed.path.strip("/").split("/")
    if parsed.hostname == "github.com" and len(parts) >= 4 and parts[2] == "pull":
        if parts[3].isdigit():
            return f"github:{parts[0]}/{parts[1]}?ref=pull/{parts[3]}/head"
    return source


class RemoteNixpkgsRunner:
    def __init__(self, session: RemoteSession, *, stderr: TextIO) -> None:
        self.session = session
        self.stderr = stderr

    def _nix_arguments(self, options: RunOptions) -> tuple[list[str], Mapping[str, str] | None]:
        arguments = ["nix", "--extra-experimental-features", "nix-command flakes"]
        environment: Mapping[str, str] | None = None
        if options.allow_unfree:
            arguments.append("--impure")
            environment = {"NIXPKGS_ALLOW_UNFREE": "1"}
        return arguments, environment

    def _run_required(
        self,
        arguments: Sequence[str],
        *,
        environment: Mapping[str, str] | None = None,
        description: str,
    ) -> str:
        result = self.session.run(arguments, environment)
        if result.stderr:
            print(result.stderr, end="" if result.stderr.endswith("\n") else "\n", file=self.stderr)
        if result.returncode != 0:
            raise RunError(f"{description} failed on {self.session.host}")
        return result.stdout

    def run(self, options: RunOptions) -> NoReturn:
        nix, environment = self._nix_arguments(options)
        print(f"Building {options.installable} on {self.session.host}...", file=self.stderr)
        build_output = self._run_required(
            [
                *nix,
                "build",
                "--no-link",
                "--print-out-paths",
                "-L",
                "--show-trace",
                options.installable,
            ],
            environment=environment,
            description="nix build",
        )
        output_paths = [line for line in build_output.splitlines() if line]
        if not output_paths:
            raise RunError(f"nix build did not return an output path for {options.installable}")
        output_path = PurePosixPath(output_paths[0])

        command = options.command
        if command is None:
            evaluated = self.session.run(
                [*nix, "eval", "--raw", f"{options.installable}.meta.mainProgram"],
                environment,
            )
            if evaluated.returncode == 0:
                command = evaluated.stdout.strip() or None
        if command is None:
            command = options.package_attribute.rsplit(".", maxsplit=1)[-1]

        run_path = PurePosixPath(command) if "/" in command else output_path / "bin" / command
        executable = self.session.run(["test", "-x", str(run_path)])
        if executable.returncode != 0:
            available = self.session.run(
                [
                    "find",
                    str(output_path / "bin"),
                    "-maxdepth",
                    "1",
                    "-type",
                    "f",
                    "-perm",
                    "-111",
                ]
            )
            details = ""
            if available.returncode == 0 and available.stdout.strip():
                candidates = "\n".join(f"  {path}" for path in available.stdout.splitlines())
                details = f"\nAvailable executables in {output_path}/bin:\n{candidates}"
            raise RunError(
                f"Unable to find executable for {options.installable}.\nTried: {run_path}{details}"
            )

        print(f"Running {run_path}...", file=self.stderr)
        self.session.replace([str(run_path), *options.program_arguments])
