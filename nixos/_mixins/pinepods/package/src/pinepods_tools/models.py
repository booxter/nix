from __future__ import annotations

from pydantic import BaseModel, ConfigDict, Field, StrictBool


class SelfServiceStatus(BaseModel):
    model_config = ConfigDict(extra="ignore", frozen=True)

    first_admin_created: StrictBool


class CreateAdminRequest(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    username: str = Field(min_length=1)
    fullname: str = Field(min_length=1)
    email: str = Field(min_length=1)
    password: str = Field(min_length=1)


class CreateAdminResponse(BaseModel):
    model_config = ConfigDict(extra="ignore", frozen=True)

    user_id: int | str
