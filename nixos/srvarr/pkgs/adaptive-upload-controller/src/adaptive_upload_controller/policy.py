from __future__ import annotations

from dataclasses import dataclass
import datetime
import logging
from pathlib import Path

from atomic_file_writes import write_text_atomic
from pydantic import (
    BaseModel,
    ConfigDict,
    Field,
    ValidationError,
    field_validator,
)

from .errors import ControllerError
from .jellyfin import collect_media_stream_stats, fetch_url_text


LOG = logging.getLogger("adaptive-upload-controller")
TARGET_MBIT_EPSILON = 0.05


@dataclass(frozen=True)
class DecisionConfig:
    exporter_url: str
    request_timeout_seconds: float
    ca_file: str
    client_cert_file: str
    client_key_file: str
    media_types: frozenset[str]
    no_streams_mbit: float
    minimum_streams_mbit: float
    fallback_mbit: float
    stream_bitrate_headroom_fraction: float
    relaxation_hold_seconds: float
    transmission_headroom_fraction: float


@dataclass(frozen=True)
class ObservedPolicy:
    active_external_media_bitrate_bits_per_second: int | None
    active_external_media_streams: int | None
    active_media_streams_total: int | None
    exporter_ok: bool
    missing_external_media_bitrate_sessions: int | None
    reason: str
    reserved_external_media_bandwidth_mbit: float | None
    target_mbit: float


class PolicyState(BaseModel):
    model_config = ConfigDict(extra="ignore", strict=True)

    active_external_media_bitrate_bits_per_second: int | None = Field(
        default=None,
        ge=0,
    )
    active_external_media_streams: int | None = Field(default=None, ge=0)
    active_media_streams_total: int | None = Field(default=None, ge=0)
    exporter_ok: bool
    missing_external_media_bitrate_sessions: int | None = Field(
        default=None,
        ge=0,
    )
    observed_reason: str
    observed_target_mbit: float = Field(gt=0)
    reason: str
    relaxation_hold_seconds: float = Field(ge=0)
    relaxation_pending_since: datetime.datetime | None = None
    relaxation_pending_target_mbit: float | None = Field(default=None, gt=0)
    reserved_external_media_bandwidth_mbit: float | None = Field(default=None, ge=0)
    target_mbit: float = Field(gt=0)
    target_tc_rate: str
    transmission_upload_limit_kbps: int = Field(gt=0)
    updated_at: datetime.datetime

    @field_validator("relaxation_pending_since", "updated_at")
    @classmethod
    def normalize_datetime(
        cls,
        value: datetime.datetime | None,
    ) -> datetime.datetime | None:
        if value is None:
            return None
        if value.tzinfo is None:
            return value.replace(tzinfo=datetime.timezone.utc)
        return value.astimezone(datetime.timezone.utc)

    def signature(self) -> tuple[object, ...]:
        return (
            self.target_mbit,
            self.observed_target_mbit,
            self.transmission_upload_limit_kbps,
            self.active_external_media_streams,
            self.active_external_media_bitrate_bits_per_second,
            self.active_media_streams_total,
            self.missing_external_media_bitrate_sessions,
            self.reason,
            self.observed_reason,
            self.exporter_ok,
            self.relaxation_pending_target_mbit,
            self.relaxation_pending_since,
            self.reserved_external_media_bandwidth_mbit,
        )


def utc_now() -> datetime.datetime:
    return datetime.datetime.now(datetime.timezone.utc)


def round_target_mbit(target_mbit: float) -> float:
    return round(target_mbit, 1)


def format_target_mbit(target_mbit: float) -> str:
    return f"{round_target_mbit(target_mbit):.1f}".rstrip("0").rstrip(".")


def calculate_transmission_upload_limit_kbps(
    target_mbit: float,
    headroom_fraction: float,
) -> int:
    return max(1, int((target_mbit * 1000.0 / 8.0) * headroom_fraction))


def default_policy_state(
    fallback_mbit: float,
    transmission_headroom_fraction: float,
    reason: str,
    exporter_ok: bool,
    active_external_media_streams: int | None,
) -> PolicyState:
    target_mbit = float(fallback_mbit)
    return PolicyState(
        active_external_media_streams=active_external_media_streams,
        active_media_streams_total=active_external_media_streams,
        exporter_ok=exporter_ok,
        observed_reason=reason,
        observed_target_mbit=target_mbit,
        reason=reason,
        relaxation_hold_seconds=0,
        target_mbit=target_mbit,
        target_tc_rate=f"{format_target_mbit(target_mbit)}mbit",
        transmission_upload_limit_kbps=calculate_transmission_upload_limit_kbps(
            target_mbit,
            transmission_headroom_fraction,
        ),
        updated_at=utc_now(),
    )


def observed_policy_from_stream_stats(
    config: DecisionConfig,
    *,
    total_media_streams: int,
    active_external_media_streams: int,
    active_external_media_bitrate_bits_per_second: int,
    missing_external_media_bitrate_sessions: int,
) -> ObservedPolicy:
    if active_external_media_streams == 0:
        target_mbit = config.no_streams_mbit
        reason = "no_active_media_streams"
        reserved_mbit = 0.0
    elif missing_external_media_bitrate_sessions > 0:
        target_mbit = config.minimum_streams_mbit
        reason = "active_media_streams_missing_bitrate"
        reserved_mbit = None
    else:
        reserved_mbit = round_target_mbit(
            (active_external_media_bitrate_bits_per_second / 1_000_000.0)
            * (1.0 + config.stream_bitrate_headroom_fraction)
        )
        target_mbit = round_target_mbit(
            min(
                config.no_streams_mbit,
                max(config.minimum_streams_mbit, config.no_streams_mbit - reserved_mbit),
            )
        )
        reason = "bitrate_based_active_media_streams"

    return ObservedPolicy(
        active_external_media_bitrate_bits_per_second=(
            active_external_media_bitrate_bits_per_second
        ),
        active_external_media_streams=active_external_media_streams,
        active_media_streams_total=total_media_streams,
        exporter_ok=True,
        missing_external_media_bitrate_sessions=missing_external_media_bitrate_sessions,
        reason=reason,
        reserved_external_media_bandwidth_mbit=reserved_mbit,
        target_mbit=target_mbit,
    )


def fallback_observed_policy(config: DecisionConfig, reason: str) -> ObservedPolicy:
    return ObservedPolicy(
        active_external_media_bitrate_bits_per_second=None,
        active_external_media_streams=None,
        active_media_streams_total=None,
        exporter_ok=False,
        missing_external_media_bitrate_sessions=None,
        reason=reason,
        reserved_external_media_bandwidth_mbit=None,
        target_mbit=config.fallback_mbit,
    )


def load_decider_state(
    state_file: Path,
    config: DecisionConfig,
) -> tuple[float | None, float | None, datetime.datetime | None]:
    try:
        state = PolicyState.model_validate_json(state_file.read_bytes())
    except (OSError, ValidationError):
        return None, None, None

    effective_target_value = round_target_mbit(state.target_mbit)
    effective_target: float | None = (
        effective_target_value
        if config.minimum_streams_mbit - TARGET_MBIT_EPSILON
        <= effective_target_value
        <= config.no_streams_mbit + TARGET_MBIT_EPSILON
        else None
    )

    pending_target = state.relaxation_pending_target_mbit
    pending_since = state.relaxation_pending_since
    if pending_target is None or pending_since is None:
        return effective_target, None, None
    pending_target = round_target_mbit(pending_target)
    if (
        not config.minimum_streams_mbit - TARGET_MBIT_EPSILON
        <= pending_target
        <= (config.no_streams_mbit + TARGET_MBIT_EPSILON)
    ):
        return effective_target, None, None
    return effective_target, pending_target, pending_since


def build_policy_state(
    *,
    config: DecisionConfig,
    observed: ObservedPolicy,
    effective_target_mbit: float,
    effective_reason: str,
    relaxation_pending_target_mbit: float | None,
    relaxation_pending_since: datetime.datetime | None,
) -> PolicyState:
    effective_target_mbit = round_target_mbit(effective_target_mbit)
    return PolicyState(
        active_external_media_bitrate_bits_per_second=(
            observed.active_external_media_bitrate_bits_per_second
        ),
        active_external_media_streams=observed.active_external_media_streams,
        active_media_streams_total=observed.active_media_streams_total,
        exporter_ok=observed.exporter_ok,
        missing_external_media_bitrate_sessions=(observed.missing_external_media_bitrate_sessions),
        observed_reason=observed.reason,
        observed_target_mbit=observed.target_mbit,
        reason=effective_reason,
        relaxation_hold_seconds=config.relaxation_hold_seconds,
        relaxation_pending_since=relaxation_pending_since,
        relaxation_pending_target_mbit=(
            round_target_mbit(relaxation_pending_target_mbit)
            if relaxation_pending_target_mbit is not None
            else None
        ),
        reserved_external_media_bandwidth_mbit=(observed.reserved_external_media_bandwidth_mbit),
        target_mbit=effective_target_mbit,
        target_tc_rate=f"{format_target_mbit(effective_target_mbit)}mbit",
        transmission_upload_limit_kbps=calculate_transmission_upload_limit_kbps(
            effective_target_mbit,
            config.transmission_headroom_fraction,
        ),
        updated_at=utc_now(),
    )


def decide_observed_policy(config: DecisionConfig) -> ObservedPolicy:
    try:
        metrics_text = fetch_url_text(
            config.exporter_url,
            config.request_timeout_seconds,
            ca_file=config.ca_file,
            client_cert_file=config.client_cert_file,
            client_key_file=config.client_key_file,
        )
        stats = collect_media_stream_stats(metrics_text, config.media_types)
        return observed_policy_from_stream_stats(
            config,
            total_media_streams=stats.total,
            active_external_media_streams=stats.external,
            active_external_media_bitrate_bits_per_second=stats.external_bitrate_bps,
            missing_external_media_bitrate_sessions=stats.external_missing_bitrate,
        )
    except ControllerError as error:
        LOG.warning("using conservative fallback after exporter failure: %s", error)
        return fallback_observed_policy(config, "exporter_unreachable")


def decide_effective_policy(
    config: DecisionConfig,
    state_file: Path,
    *,
    now: datetime.datetime | None = None,
) -> PolicyState:
    observed = decide_observed_policy(config)
    current_target, pending_target, pending_since = load_decider_state(state_file, config)
    decision_time = now or utc_now()

    if current_target is None or observed.target_mbit < current_target - TARGET_MBIT_EPSILON:
        return build_policy_state(
            config=config,
            observed=observed,
            effective_target_mbit=observed.target_mbit,
            effective_reason=observed.reason,
            relaxation_pending_target_mbit=None,
            relaxation_pending_since=None,
        )
    if abs(observed.target_mbit - current_target) <= TARGET_MBIT_EPSILON:
        return build_policy_state(
            config=config,
            observed=observed,
            effective_target_mbit=current_target,
            effective_reason=observed.reason,
            relaxation_pending_target_mbit=None,
            relaxation_pending_since=None,
        )
    if (
        pending_target is None
        or abs(pending_target - observed.target_mbit) > TARGET_MBIT_EPSILON
        or pending_since is None
    ):
        return build_policy_state(
            config=config,
            observed=observed,
            effective_target_mbit=current_target,
            effective_reason=f"holding_before_relaxation_to_{observed.reason}",
            relaxation_pending_target_mbit=observed.target_mbit,
            relaxation_pending_since=decision_time,
        )
    if (decision_time - pending_since).total_seconds() >= config.relaxation_hold_seconds:
        return build_policy_state(
            config=config,
            observed=observed,
            effective_target_mbit=observed.target_mbit,
            effective_reason=observed.reason,
            relaxation_pending_target_mbit=None,
            relaxation_pending_since=None,
        )
    return build_policy_state(
        config=config,
        observed=observed,
        effective_target_mbit=current_target,
        effective_reason=f"holding_before_relaxation_to_{observed.reason}",
        relaxation_pending_target_mbit=pending_target,
        relaxation_pending_since=pending_since,
    )


def save_policy_state(path: Path, state: PolicyState) -> None:
    write_text_atomic(path, f"{state.model_dump_json(indent=2)}\n")


def load_policy_state(
    state_file: Path,
    fallback_mbit: float,
    transmission_headroom_fraction: float,
    max_state_age_seconds: float | None,
    *,
    now: datetime.datetime | None = None,
) -> PolicyState:
    fallback = default_policy_state(
        fallback_mbit,
        transmission_headroom_fraction,
        "missing_or_invalid_state_file",
        False,
        None,
    )
    try:
        state = PolicyState.model_validate_json(state_file.read_bytes())
    except (OSError, ValidationError) as error:
        LOG.warning("unable to load policy state %s: %s", state_file, error)
        return fallback

    if max_state_age_seconds is not None:
        updated_at = state.updated_at
        if updated_at.tzinfo is None:
            updated_at = updated_at.replace(tzinfo=datetime.timezone.utc)
        age_seconds = ((now or utc_now()) - updated_at).total_seconds()
        if age_seconds > max_state_age_seconds:
            LOG.warning(
                "state file %s is stale (age %.1fs exceeds %.1fs)",
                state_file,
                age_seconds,
                max_state_age_seconds,
            )
            return fallback.model_copy(update={"reason": "stale_state_file"})
    return state
