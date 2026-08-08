from __future__ import annotations

from typing import Protocol

from pystemd.systemd1 import Unit


class UnitState(Protocol):
    def is_active(self, unit_name: str) -> bool: ...


def active_state(value: bytes | str) -> bool:
    return value in (b"active", "active")


class PystemdUnitState:
    def is_active(self, unit_name: str) -> bool:
        with Unit(unit_name.encode()) as unit:
            return active_state(unit.Unit.ActiveState)
