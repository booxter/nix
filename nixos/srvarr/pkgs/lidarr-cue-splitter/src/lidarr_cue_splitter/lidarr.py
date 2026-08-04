from __future__ import annotations

import asyncio
from collections.abc import Awaitable, Callable
from pathlib import Path
from typing import Any, Protocol, TypeVar, cast

from aiopyarr.const import HTTPMethod
from aiopyarr.exceptions import ArrException
from aiopyarr.lidarr_client import LidarrClient as NativeLidarrClient
from aiopyarr.models.base import BaseModel

from .errors import CueSplitterError
from .models import CommandStatus, ManualImportCandidate, ManualImportFile, QueueRecord


T = TypeVar("T")


class Lidarr(Protocol):
    def queue(self) -> list[QueueRecord]: ...

    def manual_import(self, folder: Path, record: QueueRecord) -> list[ManualImportCandidate]: ...

    def submit_manual_import(self, files: list[ManualImportFile]) -> int: ...

    def command(self, command_id: int) -> CommandStatus: ...

    def detach_queue_item(self, queue_id: int, *, blocklist: bool) -> None: ...


def _attributes(model: BaseModel) -> dict[str, Any]:
    return cast(dict[str, Any], model.attributes)


class LidarrClient:
    def __init__(self, base_url: str, api_key: str, timeout_seconds: float = 20.0):
        self.base_url = base_url.rstrip("/")
        self.api_key = api_key
        self.timeout_seconds = timeout_seconds

    async def _request(self, operation: Callable[[NativeLidarrClient], Awaitable[T]]) -> T:
        async with NativeLidarrClient(
            url=self.base_url,
            api_token=self.api_key,
            request_timeout=self.timeout_seconds,
        ) as request_client:
            # aiopyarr's context manager is typed as its base RequestClient.
            client = cast(NativeLidarrClient, request_client)
            return await operation(client)

    def _run(self, operation: Callable[[NativeLidarrClient], Awaitable[T]]) -> T:
        try:
            return asyncio.run(self._request(operation))
        except ArrException as error:
            raise CueSplitterError(f"Lidarr API request failed: {error}") from error

    def queue(self) -> list[QueueRecord]:
        async def get_queue(client: NativeLidarrClient) -> list[QueueRecord]:
            queue = await client.async_get_queue(
                page=1,
                page_size=2000,
                unknown_artists=True,
            )
            return [QueueRecord.model_validate(_attributes(record)) for record in queue.records]

        return self._run(get_queue)

    def manual_import(self, folder: Path, record: QueueRecord) -> list[ManualImportCandidate]:
        async def get_manual_import(client: NativeLidarrClient) -> list[ManualImportCandidate]:
            records = await client.async_get_manual_import(
                folder=str(folder),
                downloadid=record.download_id,
                artistid=record.artist_id,
                replaceexistingfiles=True,
                filterexistingfiles=False,
            )
            return [ManualImportCandidate.model_validate(_attributes(item)) for item in records]

        return self._run(get_manual_import)

    def submit_manual_import(self, files: list[ManualImportFile]) -> int:
        async def submit(client: NativeLidarrClient) -> object:
            return await client.async_command_other(
                "command",
                data={
                    "name": "ManualImport",
                    "files": [file.model_dump(by_alias=True, mode="json") for file in files],
                    "importMode": "auto",
                    "replaceExistingFiles": True,
                },
                method=HTTPMethod.POST,
            )

        payload = self._run(submit)
        command_id = payload.get("id") if isinstance(payload, dict) else None
        if not isinstance(command_id, int) or command_id <= 0:
            raise CueSplitterError("Lidarr did not return a manual-import command ID")
        return command_id

    def command(self, command_id: int) -> CommandStatus:
        async def get_command(client: NativeLidarrClient) -> object:
            return await client.async_command_other(f"command/{command_id}")

        payload = self._run(get_command)
        try:
            return CommandStatus.model_validate(payload)
        except ValueError as error:
            raise CueSplitterError("Lidarr command response has an unexpected shape") from error

    def detach_queue_item(self, queue_id: int, *, blocklist: bool) -> None:
        async def detach(client: NativeLidarrClient) -> None:
            await client.async_delete_queue(
                queue_id,
                remove_from_client=False,
                blocklist=blocklist,
                skipredownload=True,
            )

        self._run(detach)
