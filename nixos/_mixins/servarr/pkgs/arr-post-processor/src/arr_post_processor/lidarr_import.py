from __future__ import annotations

import time
from pathlib import Path
from typing import Callable

from .errors import ManualMatchRequired, NeedsAttention, PostProcessorError
from .lidarr import Lidarr
from .media import build_manual_import_files
from .models import QueueRecord


TERMINAL_COMMAND_STATES = {"completed", "failed", "aborted", "cancelled", "orphaned"}


class LidarrImporter:
    def __init__(
        self,
        *,
        command_timeout_seconds: float,
        sleep: Callable[[float], None] = time.sleep,
    ):
        self.command_timeout_seconds = command_timeout_seconds
        self.sleep = sleep

    def import_files(
        self,
        client: Lidarr,
        record: QueueRecord,
        root: Path,
        audio_files: tuple[Path, ...],
    ) -> int:
        try:
            outputs = client.manual_import(root, record)
            import_files = build_manual_import_files(outputs, list(audio_files), record)
            command_id = client.submit_manual_import(import_files)
            deadline = time.monotonic() + self.command_timeout_seconds
            while time.monotonic() < deadline:
                command = client.command(command_id)
                status = command.status.lower()
                if status in TERMINAL_COMMAND_STATES:
                    if status != "completed":
                        raise ManualMatchRequired(
                            f"Lidarr manual-import command {command_id} ended as {status}: "
                            f"{command.message}"
                        )
                    return command_id
                self.sleep(2.0)
            raise ManualMatchRequired(f"Lidarr manual-import command {command_id} timed out")
        except ManualMatchRequired:
            raise
        except PostProcessorError as exc:
            raise ManualMatchRequired(
                f"Lidarr could not import the processed tracks: {exc}"
            ) from exc
        except Exception as exc:
            raise NeedsAttention(
                f"unexpected failure after processing; generated files were preserved: {exc}"
            ) from exc
