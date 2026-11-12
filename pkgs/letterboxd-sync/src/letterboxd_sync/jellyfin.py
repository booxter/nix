import re
from collections.abc import Iterator
from contextlib import contextmanager
from typing import Protocol, cast

from jellyfin_apiclient_python import JellyfinClient  # type: ignore[import-untyped]
from jellyfin_apiclient_python.exceptions import HTTPException  # type: ignore[import-untyped]
from pydantic import TypeAdapter

from .models import Item, Items, SyncError, User


class LibraryApi(Protocol):
    def get_users(self) -> object: ...

    def items(self, *, params: dict[str, str | int | bool]) -> object: ...


@contextmanager
def connect(base_url: str, token: str) -> Iterator["Jellyfin"]:
    client = JellyfinClient()
    client.config.app("letterboxd-sync", "0.1.0", "nixos", "letterboxd-sync")
    client.config.auth(base_url, "", token=token, ssl=True)
    client.config.http(max_retries=0, timeout=60)

    try:
        yield Jellyfin(cast(LibraryApi, client.jellyfin))
    except HTTPException:
        raise SyncError("Unable to query Jellyfin; check connectivity and the API key") from None
    finally:
        client.stop()


class Jellyfin:
    def __init__(self, api: LibraryApi) -> None:
        self.api = api

    def watched(self, username: str) -> set[str]:
        user_id = self._user_id(username)
        result: set[str] = set()

        for movie in self._movies(user_id):
            if movie.kind != "Movie" or not movie.user_data.played:
                continue

            imdb_id = movie.providers.get("Imdb", "")
            if re.fullmatch(r"tt[0-9]+", imdb_id):
                result.add(imdb_id)

        return result

    def _user_id(self, username: str) -> str:
        users = TypeAdapter(list[User]).validate_python(self.api.get_users())
        matches = [user for user in users if user.name == username]
        if len(matches) != 1:
            raise SyncError("The configured Jellyfin account was not found uniquely")
        return matches[0].id

    def _movies(self, user_id: str) -> Iterator[Item]:
        offset = 0
        seen: set[str] = set()

        while True:
            response = self.api.items(
                params={
                    "UserId": user_id,
                    "Recursive": True,
                    "IncludeItemTypes": "Movie",
                    "IsPlayed": True,
                    "Fields": "ProviderIds",
                    "EnableUserData": True,
                    "EnableImages": False,
                    "SortBy": "SortName",
                    "StartIndex": offset,
                    "Limit": 500,
                }
            )
            page = Items.model_validate(response)

            for movie in page.items:
                # A changing library can shift page boundaries. Retry rather than
                # accepting a partial snapshot and silently missing watched movies.
                if movie.id in seen:
                    raise SyncError("Jellyfin pagination repeated a movie; retry the sync")
                seen.add(movie.id)
                yield movie

            offset += len(page.items)
            if offset >= page.total:
                return
            if not page.items:
                raise SyncError("Jellyfin returned an incomplete watched-movie list")
