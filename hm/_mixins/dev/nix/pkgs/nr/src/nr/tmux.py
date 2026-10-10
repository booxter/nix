import os
import re
import sys
from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Annotated
from uuid import uuid4

from nr.process import CommandRunner, ProcessRunner, checked
from nr.review import ReviewRequest
from pydantic import BaseModel, ConfigDict, StringConstraints, ValidationError


class Submission(BaseModel):
    model_config = ConfigDict(frozen=True, extra="forbid", strict=True)

    window: Annotated[str, StringConstraints(pattern=r"^(pr-[0-9]+|review)-[0-9a-f]{8}$")]


@dataclass(frozen=True)
class TmuxLauncher:
    runner: CommandRunner
    checkout: Path
    worker: Sequence[str]
    tmux: Sequence[str] = ("tmux",)

    def submit(self, request: ReviewRequest) -> Submission:
        self._validate_checkout()
        number = re.search(r"\d+$", request.pull_requests[0].rstrip("/"))
        label = f"pr-{number[0]}" if number else "review"
        window = f"{label}-{uuid4().hex[:8]}"
        command = [*self.worker, request.model_dump_json()]
        directory = str(self.checkout)

        # Try creation first: has-session followed by new-session would race
        # when two clients submit the first jobs at the same time.
        created = self.runner.run(
            [*self.tmux, "new-session", "-d", "-s", "nr", "-n", window, "-c", directory, *command]
        )
        if created.returncode:
            existing = self.runner.run([*self.tmux, "has-session", "-t", "=nr"])
            if existing.returncode:
                checked(created)
            checked(
                self.runner.run(
                    [
                        *self.tmux,
                        "new-window",
                        "-d",
                        "-t",
                        "nr:",
                        "-n",
                        window,
                        "-c",
                        directory,
                        *command,
                    ]
                )
            )
        # tmux can return success even when its server fails to start (for
        # example when a sandbox denies the socket). Confirm the window exists.
        checked(
            self.runner.run(
                [*self.tmux, "display-message", "-p", "-t", f"=nr:={window}", "#{window_id}"]
            )
        )
        return Submission(window=window)

    def _validate_checkout(self) -> None:
        if not self.checkout.is_dir():
            raise RuntimeError(f"Remote nixpkgs checkout does not exist: {self.checkout}")
        repository = self.runner.run(
            ["git", "cat-file", "-e", "HEAD:nixos/release.nix"], cwd=self.checkout
        )
        if repository.returncode:
            raise RuntimeError(f"Not a nixpkgs Git checkout: {self.checkout}")


def main() -> int:
    try:
        request = ReviewRequest.model_validate_json(sys.stdin.read())
        checkout = (
            Path(os.environ.get("NR_REVIEW_DIRECTORY", "~/src/nixpkgs")).expanduser().resolve()
        )
        # The sibling wrapper belongs to this package, even if PATH contains
        # another nr version or the tmux server inherited an old environment.
        worker = Path(sys.argv[0]).resolve().with_name("nr-worker")
        if not worker.is_file():
            raise RuntimeError(f"Remote review worker is missing: {worker}")
        result = TmuxLauncher(ProcessRunner(), checkout, (str(worker),)).submit(request)
        print(result.model_dump_json())
    except (OSError, RuntimeError, ValidationError) as error:
        print(f"nr: {error}", file=sys.stderr)
        return 1
    return 0
