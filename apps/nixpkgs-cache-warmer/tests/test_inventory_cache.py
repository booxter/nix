from datetime import datetime, timedelta, timezone
from pathlib import Path

from nixpkgs_cache_warmer.commands import CommandError
from nixpkgs_cache_warmer.inventory_cache import (
    CachedInventory,
    InventoryCacheKey,
    InventoryCacheStore,
)
from nixpkgs_cache_warmer.models import PackageSelector, PackageTarget


NOW = datetime(2026, 8, 22, 12, 0, tzinfo=timezone.utc)
KEY = InventoryCacheKey("github:NixOS/nixpkgs/staging", "booxter", "x86_64-linux")
SELECTORS = (("one",),)
TARGET = PackageTarget(
    drvPath=Path("/nix/store/one.drv"),
    name="one-1",
    pname="one",
    outputs=(Path("/nix/store/one"),),
)


class FixedClock:
    def now(self) -> datetime:
        return NOW


class FakeSelectorInventory:
    def __init__(self, discovered: tuple[PackageSelector, ...] = SELECTORS) -> None:
        self.discovered = discovered
        self.discovery_calls = 0
        self.instantiation_sources: list[Path] = []
        self.fail_instantiation = False

    def discover(self, source: Path, maintainer: str, system: str) -> tuple[PackageSelector, ...]:
        self.discovery_calls += 1
        return self.discovered

    def instantiate_selected(
        self,
        source: Path,
        maintainer: str,
        system: str,
        exclude_pname_patterns: tuple[str, ...],
        include_pname_patterns: tuple[str, ...],
        selectors: tuple[PackageSelector, ...],
    ) -> tuple[PackageTarget, ...]:
        self.instantiation_sources.append(source)
        if self.fail_instantiation:
            self.fail_instantiation = False
            raise CommandError("cached attribute disappeared")
        assert selectors == self.discovered
        return (TARGET,)


def test_cache_store_keys_entries_and_expires_them(tmp_path: Path) -> None:
    path = tmp_path / "inventory.json"
    store = InventoryCacheStore(path)
    store.put(KEY, SELECTORS, NOW)

    assert store.get(KEY, NOW + timedelta(days=6), timedelta(days=7)) == SELECTORS
    assert store.get(KEY, NOW + timedelta(days=7), timedelta(days=7)) is None
    assert (
        store.get(
            InventoryCacheKey(KEY.reference, KEY.maintainer, "aarch64-darwin"),
            NOW,
            timedelta(days=7),
        )
        is None
    )
    assert path.stat().st_mode & 0o777 == 0o644


def test_cached_inventory_reuses_selectors_for_current_source(tmp_path: Path) -> None:
    inventory = FakeSelectorInventory()
    cached = CachedInventory(
        inventory,
        InventoryCacheStore(tmp_path / "inventory.json"),
        timedelta(days=7),
        FixedClock(),
    )

    cached.instantiate(Path("/source/old"), KEY.reference, KEY.maintainer, KEY.system)
    cached.instantiate(Path("/source/current"), KEY.reference, KEY.maintainer, KEY.system)

    assert inventory.discovery_calls == 1
    assert inventory.instantiation_sources == [Path("/source/old"), Path("/source/current")]


def test_cached_inventory_refreshes_stale_selector_after_failure(tmp_path: Path) -> None:
    store = InventoryCacheStore(tmp_path / "inventory.json")
    store.put(KEY, SELECTORS, NOW)
    inventory = FakeSelectorInventory()
    inventory.fail_instantiation = True
    cached = CachedInventory(inventory, store, timedelta(days=7), FixedClock())

    targets = cached.instantiate(Path("/source"), KEY.reference, KEY.maintainer, KEY.system)

    assert targets == (TARGET,)
    assert inventory.discovery_calls == 1
    assert len(inventory.instantiation_sources) == 2


def test_cached_inventory_recovers_from_corrupt_cache(tmp_path: Path) -> None:
    path = tmp_path / "inventory.json"
    path.write_text('{"schema_version":2}')
    inventory = FakeSelectorInventory()
    cached = CachedInventory(inventory, InventoryCacheStore(path), timedelta(days=7), FixedClock())

    cached.instantiate(Path("/source"), KEY.reference, KEY.maintainer, KEY.system)

    assert inventory.discovery_calls == 1
    assert '"schema_version": 1' in path.read_text()
