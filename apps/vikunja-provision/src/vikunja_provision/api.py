from __future__ import annotations

from collections.abc import Iterator
from typing import Protocol
from urllib.parse import quote

import httpx2
from pydantic import BaseModel, SecretStr, ValidationError
from vikunja_provision.models import (
    Bot,
    BotSpec,
    IssuedToken,
    ProvisionError,
    Share,
    Token,
    TokenSpec,
)


class Vikunja(Protocol):
    def bots(self) -> list[Bot]: ...

    def shares(self, project_id: int) -> list[Share]: ...

    def tokens(self, bot_id: int) -> list[Token]: ...

    def create_bot(self, desired: BotSpec) -> Bot: ...

    def update_bot(self, bot: Bot, desired: BotSpec) -> None: ...

    def set_share(self, project_id: int, share: Share, *, exists: bool) -> None: ...

    def issue_token(self, bot_id: int, desired: TokenSpec) -> IssuedToken: ...

    def delete_token(self, token_id: int) -> None: ...


class Page[T: BaseModel](BaseModel):
    items: list[T]
    page: int
    total_pages: int


class UpdateBot(BotSpec):
    status: int = 0


class CreateToken(TokenSpec):
    owner_id: int


class HttpVikunja:
    def __init__(self, client: httpx2.Client, server: str, session: SecretStr) -> None:
        self.client = client
        self.base_url = server + "/api/v2"
        self.authorization = "Bearer " + session.get_secret_value()

    def _request(
        self,
        method: str,
        path: str,
        *,
        body: BaseModel | None = None,
        params: dict[str, int] | None = None,
    ) -> httpx2.Response:
        try:
            response = self.client.request(
                method,
                self.base_url + path,
                headers={"Authorization": self.authorization},
                json=body.model_dump(mode="json") if body is not None else None,
                params=params,
                follow_redirects=False,
            )
        except httpx2.RequestError as error:
            raise ProvisionError(f"Could not reach Vikunja: {method} {path}") from error

        if not response.is_success:
            # Response bodies can contain credentials or user content. Keep them out of logs.
            message = f"Vikunja returned HTTP {response.status_code}: {method} {path}"
            if response.status_code == 401:
                message += "; supply a valid user-session token, not an API token"
            raise ProvisionError(message)

        return response

    def _read[T: BaseModel](self, response: httpx2.Response, model: type[T]) -> T:
        try:
            return model.model_validate_json(response.content)
        except ValidationError as error:
            raise ProvisionError("Vikunja returned an invalid response") from error

    def _pages[T: BaseModel](
        self, path: str, page_model: type[Page[T]], *, owner_id: int | None = None
    ) -> Iterator[T]:
        page_number = 1
        while True:
            params = {"page": page_number}
            if owner_id is not None:
                params["owner_id"] = owner_id

            response = self._request("GET", path, params=params)
            page = self._read(response, page_model)
            if page.page != page_number:
                raise ProvisionError("Vikunja returned an unexpected page number")

            yield from page.items
            if page_number >= page.total_pages:
                return

            if not page.items:
                raise ProvisionError("Vikunja returned an empty page before the end of the list")

            page_number += 1

    def bots(self) -> list[Bot]:
        return list(self._pages("/user/bots", Page[Bot]))

    def shares(self, project_id: int) -> list[Share]:
        return list(self._pages(f"/projects/{project_id}/users", Page[Share]))

    def tokens(self, bot_id: int) -> list[Token]:
        return list(self._pages("/tokens", Page[Token], owner_id=bot_id))

    def create_bot(self, desired: BotSpec) -> Bot:
        return self._read(self._request("POST", "/user/bots", body=desired), Bot)

    def update_bot(self, bot: Bot, desired: BotSpec) -> None:
        body = UpdateBot(**desired.model_dump())
        self._request("PATCH", f"/user/bots/{bot.id}", body=body)

    def set_share(self, project_id: int, share: Share, *, exists: bool) -> None:
        path = f"/projects/{project_id}/users"
        if exists:
            path += "/" + quote(share.username, safe="")

        self._request("PUT" if exists else "POST", path, body=share)

    def issue_token(self, bot_id: int, desired: TokenSpec) -> IssuedToken:
        body = CreateToken(owner_id=bot_id, **desired.model_dump())
        return self._read(self._request("POST", "/tokens", body=body), IssuedToken)

    def delete_token(self, token_id: int) -> None:
        self._request("DELETE", f"/tokens/{token_id}")
