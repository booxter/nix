from __future__ import annotations

import logging
import time
from collections.abc import Callable
from pathlib import Path

from .errors import ManualMatchRequired, NeedsAttention, PostProcessorError
from .lidarr import Lidarr
from .media import build_manual_import_files
from .models import QueueRecord

LOG = logging.getLogger("arr-post-processor.lidarr.import")
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
            LOG.info(
                "received Lidarr manual-import candidates: download_id=%s candidates=%s "
                "generated_tracks=%s",
                record.download_id,
                len(outputs),
                len(audio_files),
            )
            import_files = build_manual_import_files(outputs, list(audio_files), record)
            command_id = client.submit_manual_import(import_files)
            LOG.info(
                "submitted Lidarr manual-import command: download_id=%s command_id=%s tracks=%s",
                record.download_id,
                command_id,
                len(import_files),
            )
            deadline = time.monotonic() + self.command_timeout_seconds
            previous_status: str | None = None
            while time.monotonic() < deadline:
                command = client.command(command_id)
                status = command.status.lower()
                if status != previous_status:
                    LOG.info(
                        "Lidarr manual-import command status: download_id=%s command_id=%s "
                        "status=%s",
                        record.download_id,
                        command_id,
                        status,
                    )
                    previous_status = status
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
