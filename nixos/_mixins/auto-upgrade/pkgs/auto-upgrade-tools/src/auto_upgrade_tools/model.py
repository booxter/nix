from __future__ import annotations

from datetime import date
from pathlib import Path

from pydantic import BaseModel, ConfigDict, Field, model_validator


class UpgradeHold(BaseModel):
    model_config = ConfigDict(extra="forbid", populate_by_name=True)

    start_date: date = Field(alias="startDate")
    stop_date: date = Field(alias="stopDate")

    @model_validator(mode="after")
    def validate_range(self) -> UpgradeHold:
        if self.stop_date < self.start_date:
            raise ValueError("hold stopDate cannot precede startDate")
        return self

    def contains(self, day: date) -> bool:
        return self.start_date <= day <= self.stop_date


class UpgradeConfig(BaseModel):
    model_config = ConfigDict(extra="forbid")

    hostname: str = Field(min_length=1)
    holds: tuple[UpgradeHold, ...] = ()

    @classmethod
    def load(cls, path: Path) -> UpgradeConfig:
        return cls.model_validate_json(path.read_text(encoding="utf-8"))

    def active_hold(self, day: date) -> UpgradeHold | None:
        return next((hold for hold in self.holds if hold.contains(day)), None)
