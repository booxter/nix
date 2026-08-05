from __future__ import annotations

import math
from pathlib import Path
from typing import Annotated, Any

from pydantic import BaseModel, BeforeValidator, ConfigDict, Field, RootModel


def _chat_id(value: Any) -> int:
    if isinstance(value, bool):
        raise ValueError("a Telegram chat ID must be an integer")
    if isinstance(value, int):
        return value
    if isinstance(value, float) and math.isfinite(value) and value.is_integer():
        return int(value)
    raise ValueError("a Telegram chat ID must be an integer")


ChatId = Annotated[int, BeforeValidator(_chat_id)]
ChatIdValues = Annotated[list[ChatId], Field(min_length=1)]


class ChatIds(RootModel[ChatIdValues]):
    pass


class CredentialPaths(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True, strict=True)

    api_id: Path
    api_hash: Path
    phone: Path
    chat_ids: Path


class AuthConfig(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True, strict=True)

    executable: Path
    scheduler_unit: str = Field(min_length=1)
    user: str = Field(min_length=1)
    state_directory: Path
    credentials: CredentialPaths
    environment: dict[str, str]
