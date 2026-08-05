from __future__ import annotations

from typing import Protocol

from pystemd.systemd1 import Manager


class UnitRestarter(Protocol):
    def try_restart(self, unit: str) -> None: ...


class SystemdUnitRestarter:
    def try_restart(self, unit: str) -> None:
        with Manager() as manager:
            manager.Manager.TryRestartUnit(unit.encode(), b"replace")
