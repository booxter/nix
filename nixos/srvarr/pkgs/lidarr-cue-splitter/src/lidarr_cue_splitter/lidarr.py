from __future__ import annotations

import asyncio
from collections.abc import Awaitable, Callable
from pathlib import Path
from typing import Any, TypeVar, cast

from aiopyarr.const import HTTPMethod
from aiopyarr.exceptions import ArrException
from aiopyarr.lidarr_client import LidarrClient as NativeLidarrClient
from aiopyarr.models.base import BaseModel

from .errors import CueSplitterError


T = TypeVar("T")


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
        ) as client:
            return await operation(client)

    def _run(self, operation: Callable[[NativeLidarrClient], Awaitable[T]]) -> T:
        try:
            return asyncio.run(self._request(operation))
        except ArrException as error:
            raise CueSplitterError(f"Lidarr API request failed: {error}") from error

    def queue(self) -> list[dict[str, Any]]:
        async def get_queue(client: NativeLidarrClient) -> list[dict[str, Any]]:
            queue = await client.async_get_queue(
                page=1,
                page_size=2000,
                unknown_artists=True,
            )
            return [_attributes(record) for record in queue.records]

        return self._run(get_queue)

    def manual_import(self, folder: Path, record: dict[str, Any]) -> list[dict[str, Any]]:
        async def get_manual_import(client: NativeLidarrClient) -> list[dict[str, Any]]:
            records = await client.async_get_manual_import(
                folder=str(folder),
                downloadid=str(record.get("downloadId", "")),
                artistid=int(record.get("artistId") or 0),
                replaceexistingfiles=True,
                filterexistingfiles=False,
            )
            return [_attributes(item) for item in records]

        return self._run(get_manual_import)

    def submit_manual_import(self, files: list[dict[str, Any]]) -> int:
        async def submit(client: NativeLidarrClient) -> object:
            return await client.async_command_other(
                "command",
                data={
                    "name": "ManualImport",
                    "files": files,
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

    def command(self, command_id: int) -> dict[str, Any]:
        async def get_command(client: NativeLidarrClient) -> object:
            return await client.async_command_other(f"command/{command_id}")

        payload = self._run(get_command)
        if not isinstance(payload, dict):
            raise CueSplitterError("Lidarr command response has an unexpected shape")
        return cast(dict[str, Any], payload)

    def detach_queue_item(self, queue_id: int, *, blocklist: bool) -> None:
        async def detach(client: NativeLidarrClient) -> None:
            await client.async_delete_queue(
                queue_id,
                remove_from_client=False,
                blocklist=blocklist,
                skipredownload=True,
            )

        self._run(detach)
