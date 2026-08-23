from __future__ import annotations

import json
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Literal, Protocol

from atomic_file_writes import write_text_atomic
from pydantic import BaseModel, ConfigDict, ValidationError

from nixpkgs_cache_warmer.commands import CommandError
from nixpkgs_cache_warmer.models import PackageSelector, PackageTarget


@dataclass(frozen=True)
class InventoryCacheKey:
    reference: str
    maintainer: str
    system: str


class InventoryCacheEntry(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    reference: str
    maintainer: str
    system: str
    refreshed_at: datetime
    selectors: tuple[PackageSelector, ...]


class InventoryCache(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    schema_version: Literal[1] = 1
    entries: tuple[InventoryCacheEntry, ...] = ()


class Clock(Protocol):
    def now(self) -> datetime: ...


class SystemClock:
    def now(self) -> datetime:
        return datetime.now(timezone.utc)


class SelectorInventory(Protocol):
    def discover(
        self, source: Path, maintainer: str, system: str
    ) -> tuple[PackageSelector, ...]: ...

    def instantiate_selected(
        self,
        source: Path,
        maintainer: str,
        system: str,
        exclude_pname_patterns: tuple[str, ...],
        include_pname_patterns: tuple[str, ...],
        selectors: tuple[PackageSelector, ...],
    ) -> tuple[PackageTarget, ...]: ...


class InventoryCacheStore:
    def __init__(self, path: Path) -> None:
        self.path = path

    def get(
        self, key: InventoryCacheKey, now: datetime, max_age: timedelta
    ) -> tuple[PackageSelector, ...] | None:
        for entry in self._read().entries:
            if self._key(entry) == key and now - entry.refreshed_at < max_age:
                return entry.selectors
        return None

    def put(
        self,
        key: InventoryCacheKey,
        selectors: tuple[PackageSelector, ...],
        refreshed_at: datetime,
    ) -> None:
        current = self._read()
        entry = InventoryCacheEntry(
            reference=key.reference,
            maintainer=key.maintainer,
            system=key.system,
            refreshed_at=refreshed_at,
            selectors=selectors,
        )
        updated = InventoryCache(
            entries=tuple(item for item in current.entries if self._key(item) != key) + (entry,)
        )
        content = json.dumps(updated.model_dump(mode="json"), indent=2, sort_keys=True) + "\n"
        try:
            write_text_atomic(self.path, content, mode=0o644)
        except OSError as error:
            raise CommandError(f"failed to write inventory cache {self.path}: {error}") from error

    def _read(self) -> InventoryCache:
        try:
            content = self.path.read_text(encoding="utf-8")
        except FileNotFoundError:
            return InventoryCache()
        except OSError as error:
            raise CommandError(f"failed to read inventory cache {self.path}: {error}") from error
        try:
            return InventoryCache.model_validate_json(content)
        except ValidationError:
            return InventoryCache()

    @staticmethod
    def _key(entry: InventoryCacheEntry) -> InventoryCacheKey:
        return InventoryCacheKey(entry.reference, entry.maintainer, entry.system)


class CachedInventory:
    def __init__(
        self,
        inventory: SelectorInventory,
        store: InventoryCacheStore,
        max_age: timedelta,
        clock: Clock | None = None,
    ) -> None:
        self._inventory = inventory
        self._store = store
        self._max_age = max_age
        self._clock = clock or SystemClock()

    def instantiate(
        self,
        source: Path,
        reference: str,
        maintainer: str,
        system: str,
        exclude_pname_patterns: tuple[str, ...] = (),
        include_pname_patterns: tuple[str, ...] = (),
    ) -> tuple[PackageTarget, ...]:
        key = InventoryCacheKey(reference, maintainer, system)
        now = self._clock.now()
        selectors = self._store.get(key, now, self._max_age)
        cached = selectors is not None
        if selectors is None:
            selectors = self._refresh(source, key, now)
        try:
            return self._inventory.instantiate_selected(
                source,
                maintainer,
                system,
                exclude_pname_patterns,
                include_pname_patterns,
                selectors,
            )
        except CommandError:
            if not cached:
                raise
            selectors = self._refresh(source, key, now)
            return self._inventory.instantiate_selected(
                source,
                maintainer,
                system,
                exclude_pname_patterns,
                include_pname_patterns,
                selectors,
            )

    def _refresh(
        self, source: Path, key: InventoryCacheKey, refreshed_at: datetime
    ) -> tuple[PackageSelector, ...]:
        selectors = self._inventory.discover(source, key.maintainer, key.system)
        self._store.put(key, selectors, refreshed_at)
        return selectors
