import subprocess
from typing import Protocol

from pydantic import TypeAdapter

from .models import Flow, Qdisc, Target


class Source(Protocol):
    def read(self, target: Target) -> tuple[Qdisc, list[Flow]]:
        """Read the named queue and its current flow state."""


class Runner(Protocol):
    def run(self, arguments: list[str]) -> str:
        """Return JSON output, or raise on failure."""


class CommandRunner:
    def run(self, arguments: list[str]) -> str:
        return subprocess.run(
            arguments, check=True, capture_output=True, text=True, timeout=2
        ).stdout


class TcSource:
    def __init__(self, runner: Runner) -> None:
        self.runner = runner

    def read(self, target: Target) -> tuple[Qdisc, list[Flow]]:
        # Filter before validation: HTB and fq_codel have different schemas.
        queues = TypeAdapter(list[dict[str, object]]).validate_json(
            self.runner.run(["tc", "-j", "-s", "qdisc", "show", "dev", target.device])
        )
        selected = [
            queue
            for queue in queues
            if queue.get("kind") == "cake"
            and ("root" if queue.get("root") else queue.get("parent")) == target.parent
        ]
        if len(selected) != 1:
            raise ValueError(f"expected one CAKE queue for {target.device}/{target.parent}")
        queue = Qdisc.model_validate(selected[0])
        classes = TypeAdapter(list[dict[str, object]]).validate_json(
            self.runner.run(["tc", "-j", "-s", "class", "show", "dev", target.device])
        )
        flows = TypeAdapter(list[Flow]).validate_python(
            [flow for flow in classes if flow.get("parent") == queue.handle]
        )
        if any(flow.tin < 0 or flow.tin >= len(queue.tins) for flow in flows):
            raise ValueError("CAKE flow refers to an unknown tin")
        return queue, flows
