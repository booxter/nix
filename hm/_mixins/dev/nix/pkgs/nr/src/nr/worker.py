import os
import subprocess
import sys

from nr.process import ProcessRunner, checked
from nr.review import NixpkgsReviewExecutor, ReviewRequest, resolve_review
from pydantic import ValidationError


def main() -> int:
    status = 1
    try:
        pane = os.environ.get("TMUX_PANE")
        if pane is None:
            raise RuntimeError("nr-worker must run inside tmux")
        runner = ProcessRunner()
        # Retain the pane before parsing or starting the review, including
        # jobs that fail immediately. Only this job's window is changed.
        checked(runner.run(["tmux", "set-option", "-p", "-t", pane, "remain-on-exit", "on"]))
        checked(runner.run(["tmux", "set-option", "-w", "-t", pane, "automatic-rename", "off"]))
        checked(runner.run(["tmux", "set-option", "-w", "-t", pane, "allow-rename", "off"]))
        if len(sys.argv) != 2:
            raise RuntimeError("nr-worker requires one review request")
        request = ReviewRequest.model_validate_json(sys.argv[1])
        print(f"nr: reviewing {', '.join(request.pull_requests)}", flush=True)
        status = NixpkgsReviewExecutor().run(resolve_review(request, os.environ))
        if status < 0:
            status = 128 - status
    except KeyboardInterrupt:
        status = 130
    except (OSError, RuntimeError, ValidationError, subprocess.SubprocessError) as error:
        print(f"nr: {error}", file=sys.stderr)
    print(f"\nnr: review finished (exit {status})", flush=True)
    return status
