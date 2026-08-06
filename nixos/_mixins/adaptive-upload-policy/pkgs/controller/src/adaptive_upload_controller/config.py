from __future__ import annotations

from pathlib import Path

from pydantic import BaseModel, ConfigDict, Field, ValidationError, model_validator

from .errors import ControllerError


class ConfigModel(BaseModel):
    model_config = ConfigDict(extra="forbid")


class JellyfinSourceConfig(ConfigModel):
    exporter_url: str
    request_timeout_seconds: float = Field(gt=0)
    ca_file: str = ""
    client_cert_file: str = ""
    client_key_file: str = ""
    media_types: frozenset[str] = Field(min_length=1)
    idle_rate_mbit: float = Field(gt=0)
    minimum_rate_mbit: float = Field(gt=0)
    bitrate_headroom_fraction: float = Field(ge=0, le=1)
    relaxation_hold_seconds: float = Field(ge=0)

    @model_validator(mode="after")
    def validate_tls_credentials(self) -> JellyfinSourceConfig:
        if bool(self.client_cert_file) != bool(self.client_key_file):
            raise ValueError("client_cert_file and client_key_file must be provided together")
        if self.minimum_rate_mbit > self.idle_rate_mbit:
            raise ValueError("minimum_rate_mbit must not exceed idle_rate_mbit")
        return self


class TransmissionOutputConfig(ConfigModel):
    rpc_url: str
    request_timeout_seconds: float = Field(gt=0)
    headroom_fraction: float = Field(gt=0, le=1)


class QosOutputConfig(ConfigModel):
    executable: str
    config_file: str
    limit: str


class ControllerConfig(ConfigModel):
    state_file: Path
    metrics_file: Path | None
    interval_seconds: float = Field(gt=0)
    max_state_age_seconds: float = Field(gt=0)
    fallback_rate_mbit: float = Field(gt=0)
    jellyfin: JellyfinSourceConfig
    transmission: TransmissionOutputConfig | None = None
    qos: QosOutputConfig | None = None


def load_config(path: Path) -> ControllerConfig:
    try:
        return ControllerConfig.model_validate_json(path.read_bytes())
    except OSError as error:
        raise ControllerError(f"failed to read configuration {path}: {error}") from error
    except ValidationError as error:
        raise ControllerError(f"invalid configuration {path}: {error}") from error
