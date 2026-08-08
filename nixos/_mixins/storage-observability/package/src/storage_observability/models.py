from __future__ import annotations

from dataclasses import dataclass

from pydantic import BaseModel, ConfigDict, Field, RootModel


class ApiModel(BaseModel):
    model_config = ConfigDict(extra="ignore", strict=True)


class CommandStatus(ApiModel):
    controller: str | int = Field(default="unknown", alias="Controller")
    status: str = Field(default="", alias="Status")


class ControllerBasics(ApiModel):
    controller: str | int = Field(default="unknown", alias="Controller")
    adapter_type: str = Field(default="", alias="Adapter Type")
    model: str = Field(default="", alias="Model")
    serial: str = Field(default="", alias="Serial Number")


class ControllerVersion(ApiModel):
    driver: str = Field(default="", alias="Driver Name")
    firmware: str = Field(default="", alias="Firmware Version")


class ControllerStatus(ApiModel):
    controller_status: str = Field(default="", alias="Controller Status")
    correctable_errors: str | int | float | None = Field(
        default=None,
        alias="Memory Correctable Errors",
    )
    uncorrectable_errors: str | int | float | None = Field(
        default=None,
        alias="Memory Uncorrectable Errors",
    )


class HardwareConfig(ApiModel):
    backend_ports: str | int | float | None = Field(default=None, alias="Backend Port Count")
    temperature_celsius: str | int | float | None = Field(
        default=None,
        alias="ROC temperature(Degree Celsius)",
    )
    temperature_celcius: str | int | float | None = Field(
        default=None,
        alias="ROC temperature(Degree Celcius)",
    )


class ControllerResponse(ApiModel):
    basics: ControllerBasics = Field(default_factory=ControllerBasics, alias="Basics")
    version: ControllerVersion = Field(default_factory=ControllerVersion, alias="Version")
    status: ControllerStatus = Field(default_factory=ControllerStatus, alias="Status")
    hardware: HardwareConfig = Field(default_factory=HardwareConfig, alias="HwCfg")
    physical_devices: dict[str, object] = Field(
        default_factory=dict,
        alias="Physical Device Information",
    )


class Controller(ApiModel):
    command: CommandStatus = Field(default_factory=CommandStatus, alias="Command Status")
    response: ControllerResponse = Field(default_factory=ControllerResponse, alias="Response Data")


class StorcliDocument(ApiModel):
    controllers: list[Controller] = Field(default_factory=list, alias="Controllers")


class BayMapping(ApiModel):
    serial: str
    bay: str | int = ""
    row: str | int = ""
    col: str | int = ""
    model: str = ""


class BayMappings(RootModel[list[BayMapping]]):
    def by_serial(self) -> dict[str, BayMapping]:
        return {mapping.serial.strip(): mapping for mapping in self.root}


class DriveBasic(ApiModel):
    enclosure_slot: str | int = Field(default="", alias="EID:Slt")
    disk_id: str | int = Field(default="", alias="DID")
    interface: str = Field(default="", alias="Intf")
    media: str = Field(default="", alias="Med")
    model: str = Field(default="", alias="Model")
    state: str = Field(default="", alias="State")


@dataclass(frozen=True)
class Drive:
    controller: str
    controller_enclosure: str
    controller_slot: str
    disk_id: str
    interface: str
    media: str
    model: str
    state: str
    firmware: str
    serial: str
    bay: str
    bay_row: str
    bay_col: str
    link_speed_gbps: float | None
    connected_port: float | None
    media_errors: float | None
    other_errors: float | None
    predictive_errors: float | None
    smart_alerted: float | None

    def common_labels(self) -> tuple[str, ...]:
        return (
            self.bay,
            self.bay_col,
            self.bay_row,
            self.controller,
            self.controller_enclosure,
            self.controller_slot,
            self.model,
            self.serial,
        )
