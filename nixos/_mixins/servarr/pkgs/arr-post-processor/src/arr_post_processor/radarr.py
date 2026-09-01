from __future__ import annotations

import asyncio
from collections.abc import Awaitable, Callable
from pathlib import Path
from typing import Any, Protocol, TypeVar, cast

from aiopyarr.const import HTTPMethod
from aiopyarr.exceptions import ArrException
from aiopyarr.models.base import BaseModel
from aiopyarr.radarr_client import RadarrClient as NativeRadarrClient

from .errors import PostProcessorError
from .radarr_models import (
    CommandStatus,
    RadarrManualImportCandidate,
    RadarrManualImportFile,
    RadarrMovie,
    RadarrQueueRecord,
)

T = TypeVar("T")


class Radarr(Protocol):
    def queue(self) -> list[RadarrQueueRecord]: ...

    def movie(self, movie_id: int) -> RadarrMovie: ...

    def manual_import(
        self, folder: Path, record: RadarrQueueRecord
    ) -> list[RadarrManualImportCandidate]: ...

    def submit_manual_import(self, file: RadarrManualImportFile) -> int: ...

    def command(self, command_id: int) -> CommandStatus: ...


def _attributes(model: BaseModel) -> dict[str, Any]:
    return cast(dict[str, Any], model.attributes)


class RadarrClient:
    def __init__(self, base_url: str, api_key: str, timeout_seconds: float = 20.0):
        self.base_url = base_url.rstrip("/")
        self.api_key = api_key
        self.timeout_seconds = timeout_seconds

    async def _request(self, operation: Callable[[NativeRadarrClient], Awaitable[T]]) -> T:
        async with NativeRadarrClient(
            url=self.base_url,
            api_token=self.api_key,
            request_timeout=self.timeout_seconds,
        ) as request_client:
            client = cast(NativeRadarrClient, request_client)
            return await operation(client)

    def _run(self, operation: Callable[[NativeRadarrClient], Awaitable[T]]) -> T:
        try:
            return asyncio.run(self._request(operation))
        except ArrException as error:
            raise PostProcessorError(f"Radarr API request failed: {error}") from error

    def queue(self) -> list[RadarrQueueRecord]:
        async def get_queue(client: NativeRadarrClient) -> list[RadarrQueueRecord]:
            queue = await client.async_get_queue(
                page=1,
                page_size=2000,
                include_unknown_movie_items=True,
                include_movie=False,
            )
            return [
                RadarrQueueRecord.model_validate(_attributes(record)) for record in queue.records
            ]

        return self._run(get_queue)

    def movie(self, movie_id: int) -> RadarrMovie:
        async def get_movie(client: NativeRadarrClient) -> RadarrMovie:
            movie = await client.async_get_movies(movieid=movie_id)
            if isinstance(movie, list):
                raise PostProcessorError(f"Radarr returned no unique movie for id {movie_id}")
            return RadarrMovie.model_validate(_attributes(movie))

        return self._run(get_movie)

    def manual_import(
        self, folder: Path, record: RadarrQueueRecord
    ) -> list[RadarrManualImportCandidate]:
        async def get_manual_import(
            client: NativeRadarrClient,
        ) -> list[RadarrManualImportCandidate]:
            records = await client.async_get_manual_import(
                downloadid=record.download_id,
                folder=str(folder),
                filterexistingfiles=False,
            )
            return [
                RadarrManualImportCandidate.model_validate(_attributes(item)) for item in records
            ]

        return self._run(get_manual_import)

    def submit_manual_import(self, file: RadarrManualImportFile) -> int:
        async def submit(client: NativeRadarrClient) -> object:
            return await client.async_command_other(
                "command",
                data={
                    "name": "ManualImport",
                    "files": [file.model_dump(by_alias=True, mode="json")],
                    "importMode": "auto",
                },
                method=HTTPMethod.POST,
            )

        payload = self._run(submit)
        command_id = payload.get("id") if isinstance(payload, dict) else None
        if not isinstance(command_id, int) or command_id <= 0:
            raise PostProcessorError("Radarr did not return a manual-import command ID")
        return command_id

    def command(self, command_id: int) -> CommandStatus:
        async def get_command(client: NativeRadarrClient) -> object:
            return await client.async_command_other(f"command/{command_id}")

        payload = self._run(get_command)
        try:
            return CommandStatus.model_validate(payload)
        except ValueError as error:
            raise PostProcessorError("Radarr command response has an unexpected shape") from error
