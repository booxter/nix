from __future__ import annotations

from pydantic import BaseModel, ConfigDict, RootModel


class BayMapping(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)

    serial: str
    bay: int
    row: int
    col: int
    model: str = ""


class BayMappings(RootModel[list[BayMapping]]):
    def by_serial(self) -> dict[str, BayMapping]:
        return {mapping.serial.strip(): mapping for mapping in self.root}
