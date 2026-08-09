from __future__ import annotations

import os
import sys
from pathlib import Path
from typing import BinaryIO

from prometheus_client import CollectorRegistry, generate_latest, write_to_textfile


def render(registry: CollectorRegistry) -> bytes:
    """Render one registry using the Prometheus text exposition format."""
    return generate_latest(registry)


def write(registry: CollectorRegistry, destination: str, stdout: BinaryIO | None = None) -> None:
    """Write a registry to stdout or atomically replace a textfile."""
    if destination == "-":
        (stdout or sys.stdout.buffer).write(render(registry))
        return
    path = Path(destination)
    write_to_textfile(str(path), registry)
    os.chmod(path, 0o644)
