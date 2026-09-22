from enum import StrEnum
from pathlib import Path

from pydantic import BaseModel, ConfigDict, Field, ValidationError, model_validator


class PolicyConfigError(ValueError):
    pass


class ConfigModel(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True, strict=True)


class Priority(StrEnum):
    LOW = "low"
    NORMAL = "normal"
    HIGH = "high"


class RatioPriorityPolicy(ConfigModel):
    target_ratio: float = Field(ge=0)
    below_target: Priority
    at_or_above_target: Priority


class StopPolicy(ConfigModel):
    minimum_ratio: float = Field(ge=0)
    require_complete: bool


class CompletedCleanupPolicy(ConfigModel):
    minimum_ratio: float = Field(ge=0)
    minimum_age_days: float = Field(ge=0)


class CleanupPolicy(ConfigModel):
    completed: CompletedCleanupPolicy
    maximum_age_days: float = Field(gt=0)

    @model_validator(mode="after")
    def validate_age_order(self) -> "CleanupPolicy":
        if self.maximum_age_days < self.completed.minimum_age_days:
            raise ValueError("maximum_age_days must not be below completed minimum_age_days")
        return self


class TorrentClassPolicy(ConfigModel):
    priority: RatioPriorityPolicy
    stop: StopPolicy | None
    cleanup: CleanupPolicy | None

    @model_validator(mode="after")
    def validate_ratio_order(self) -> "TorrentClassPolicy":
        if self.stop is not None and self.stop.minimum_ratio < self.priority.target_ratio:
            raise ValueError("stop minimum_ratio must not be below priority target_ratio")
        return self


class TorrentPolicy(ConfigModel):
    preferred: TorrentClassPolicy
    non_preferred: TorrentClassPolicy

    def class_policy(self, *, preferred: bool) -> TorrentClassPolicy:
        return self.preferred if preferred else self.non_preferred


def load_policy(path: Path) -> TorrentPolicy:
    try:
        return TorrentPolicy.model_validate_json(path.read_bytes())
    except OSError as exc:
        raise PolicyConfigError(f"failed to read torrent policy {path}: {exc}") from exc
    except ValidationError as exc:
        raise PolicyConfigError(f"invalid torrent policy {path}: {exc}") from exc


def desired_priority(policy: RatioPriorityPolicy, ratio: int | float | None) -> Priority:
    if ratio is not None and ratio >= policy.target_ratio:
        return policy.at_or_above_target
    return policy.below_target


def should_stop(
    policy: StopPolicy | None,
    *,
    ratio: int | float | None,
    complete: bool,
) -> bool:
    return bool(
        policy is not None
        and ratio is not None
        and ratio >= policy.minimum_ratio
        and (complete or not policy.require_complete)
    )


def cleanup_reasons(
    policy: CleanupPolicy | None,
    *,
    ratio: int | float | None,
    complete: bool,
    completion_age_days: float | None,
    added_age_days: float | None,
) -> tuple[str, ...]:
    if policy is None:
        return ()

    reasons: list[str] = []
    if added_age_days is not None and added_age_days >= policy.maximum_age_days:
        reasons.append("maximum-age")
    if (
        complete
        and completion_age_days is not None
        and completion_age_days >= policy.completed.minimum_age_days
        and ratio is not None
        and ratio >= policy.completed.minimum_ratio
    ):
        reasons.append("high-ratio")
    return tuple(reasons)
