from __future__ import annotations

import time
from collections.abc import Callable

from prometheus_client import CollectorRegistry, Gauge, generate_latest

from .models import ProbeState, StateFile


EXPECTED_PHASES = {
    "kanidm": ("discovery", "jwks", "auth", "authorize", "token", "userinfo"),
    "searxng": ("auth", "proxy"),
}


class ProbeMetrics:
    def __init__(self, clock: Callable[[], float] = time.monotonic) -> None:
        self._clock = clock
        self._registry = CollectorRegistry()
        self._probe_ok = Gauge(
            "host_observability_oidc_synthetic_probe_ok",
            "Whether the most recent OIDC synthetic probe succeeded.",
            ("probe",),
            registry=self._registry,
        )
        self._phase_ok = Gauge(
            "host_observability_oidc_synthetic_probe_phase_ok",
            "Whether the most recent OIDC synthetic probe phase succeeded.",
            ("probe", "phase"),
            registry=self._registry,
        )
        self._phase_status = Gauge(
            "host_observability_oidc_synthetic_probe_http_status_code",
            "HTTP status code observed by the most recent OIDC synthetic probe phase.",
            ("probe", "phase"),
            registry=self._registry,
        )
        self._duration = Gauge(
            "host_observability_oidc_synthetic_probe_duration_seconds",
            "Duration of the most recent OIDC synthetic probe.",
            ("probe",),
            registry=self._registry,
        )
        self._last_run = Gauge(
            "host_observability_oidc_synthetic_probe_last_run_timestamp_seconds",
            "Unix timestamp of the most recent OIDC synthetic probe run.",
            ("probe",),
            registry=self._registry,
        )
        self._last_success = Gauge(
            "host_observability_oidc_synthetic_probe_last_success_timestamp_seconds",
            "Unix timestamp of the most recent successful OIDC synthetic probe run.",
            ("probe",),
            registry=self._registry,
        )
        self.succeeded = {probe: False for probe in EXPECTED_PHASES}
        for probe, phases in EXPECTED_PHASES.items():
            self._probe_ok.labels(probe).set(0)
            self._duration.labels(probe).set(0)
            self._last_run.labels(probe).set(0)
            self._last_success.labels(probe).set(0)
            for phase in phases:
                self._phase_ok.labels(probe, phase).set(0)
                self._phase_status.labels(probe, phase).set(0)

    def started(self) -> float:
        return self._clock()

    def record_phase(self, probe: str, phase: str, ok: bool, status: int = 0) -> None:
        self._phase_ok.labels(probe, phase).set(1 if ok else 0)
        self._phase_status.labels(probe, phase).set(status)

    def finish_probe(self, probe: str, ok: bool, started_at: float) -> None:
        self.succeeded[probe] = ok
        self._probe_ok.labels(probe).set(1 if ok else 0)
        self._duration.labels(probe).set(max(0.0, self._clock() - started_at))

    def finalize(self, state: StateFile, now: int) -> None:
        for probe in EXPECTED_PHASES:
            probe_state = state.probes.setdefault(probe, ProbeState())
            if self.succeeded[probe]:
                probe_state.last_success = now
            self._last_run.labels(probe).set(now)
            self._last_success.labels(probe).set(probe_state.last_success)

    def render(self) -> bytes:
        return generate_latest(self._registry)
