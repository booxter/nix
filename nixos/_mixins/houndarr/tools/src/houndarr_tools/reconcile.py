from __future__ import annotations

import asyncio
from collections.abc import Awaitable, Callable, Mapping
from pathlib import Path
from typing import Protocol, cast
from xml.etree import ElementTree

from .models import CurrentInstance, DesiredInstance, Interface, ManagedPolicy, Value


class ReconcileError(RuntimeError):
    pass


class InstanceConflict(ReconcileError):
    pass


class BackendUnavailable(ReconcileError):
    pass


class InstanceStore(Protocol):
    async def list(self) -> tuple[CurrentInstance, ...]: ...

    async def verify(self, interface: Interface, url: str, api_key: str) -> bool: ...

    async def create(
        self,
        desired: DesiredInstance,
        api_key: str,
        fields: Mapping[str, Value],
    ) -> None: ...

    async def update(self, instance_id: int, fields: Mapping[str, Value]) -> None: ...

    async def close(self) -> None: ...


def read_api_key(credentials_directory: Path, desired: DesiredInstance) -> str:
    source = credentials_directory / desired.credential.name
    try:
        root = ElementTree.parse(source).getroot()  # noqa: S314
    except (ElementTree.ParseError, OSError) as error:
        raise ReconcileError(f"cannot read API credential for {desired.key}") from error
    value = (root.findtext(desired.credential.field) or "").strip()
    if not value:
        raise ReconcileError(f"API credential for {desired.key} is empty")
    return value


def _search_mode_field(interface: Interface, *, upgrade: bool) -> str | None:
    prefix = "upgrade_" if upgrade else ""
    return {
        "sonarr": f"{prefix}sonarr_search_mode",
        "lidarr": f"{prefix}lidarr_search_mode",
        "readarr": f"{prefix}readarr_search_mode",
        "whisparr-v2": f"{prefix}whisparr_v2_search_mode",
    }.get(interface)


def _search_mode_value(interface: Interface, mode: str) -> str:
    return {
        "sonarr": {"item": "episode", "context": "season_context"},
        "lidarr": {"item": "album", "context": "artist_context"},
        "readarr": {"item": "book", "context": "author_context"},
        "whisparr-v2": {"item": "episode", "context": "season_context"},
    }[interface][mode]


def managed_fields(interface: Interface, policy: ManagedPolicy | None) -> dict[str, Value]:
    if policy is None:
        return {}
    dumped = policy.model_dump(exclude_none=True)
    missing_mode = dumped.pop("missing_search_mode", None)
    upgrade_mode = dumped.pop("upgrade_search_mode", None)
    for field in ("tag_filter_include", "tag_filter_exclude"):
        labels = dumped.get(field)
        if isinstance(labels, tuple):
            dumped[field] = ",".join(labels)
    for mode, upgrade in ((missing_mode, False), (upgrade_mode, True)):
        if mode is None:
            continue
        search_field = _search_mode_field(interface, upgrade=upgrade)
        if search_field is None:
            raise ReconcileError(f"{interface} does not support contextual search modes")
        dumped[search_field] = _search_mode_value(interface, cast(str, mode))
    return cast(dict[str, Value], dumped)


def find_existing(
    desired: DesiredInstance, current: tuple[CurrentInstance, ...]
) -> CurrentInstance | None:
    endpoint_matches = [
        instance
        for instance in current
        if instance.interface == desired.interface
        and instance.url.rstrip("/") == desired.url.rstrip("/")
    ]
    if len(endpoint_matches) > 1:
        raise InstanceConflict(f"multiple Houndarr instances use the endpoint for {desired.key}")
    if endpoint_matches:
        return endpoint_matches[0]
    name_matches = [
        instance
        for instance in current
        if instance.interface == desired.interface and instance.name == desired.display_name
    ]
    if len(name_matches) > 1:
        raise InstanceConflict(f"multiple Houndarr instances use the name for {desired.key}")
    if name_matches:
        return name_matches[0]
    return None


async def wait_until_verified(
    store: InstanceStore,
    desired: DesiredInstance,
    api_key: str,
    *,
    attempts: int,
    delay: float,
    sleep: Callable[[float], Awaitable[None]],
) -> None:
    for attempt in range(attempts):
        if await store.verify(desired.interface, desired.url, api_key):
            return
        if attempt + 1 < attempts:
            await sleep(delay)
    raise BackendUnavailable(f"{desired.key} API did not become ready")


async def reconcile_instances(
    store: InstanceStore,
    desired_instances: tuple[DesiredInstance, ...],
    credentials_directory: Path,
    *,
    attempts: int = 60,
    delay: float = 2.0,
    sleep: Callable[[float], Awaitable[None]] = asyncio.sleep,
) -> int:
    try:
        current = await store.list()
        claimed_ids: set[int] = set()
        changed = 0
        for desired in desired_instances:
            api_key = read_api_key(credentials_directory, desired)
            await wait_until_verified(
                store, desired, api_key, attempts=attempts, delay=delay, sleep=sleep
            )
            existing = find_existing(desired, current)
            policy_fields = managed_fields(desired.interface, desired.policy)
            if existing is None:
                await store.create(desired, api_key, policy_fields)
                changed += 1
                continue
            if existing.id in claimed_ids:
                raise InstanceConflict(
                    f"multiple declarations adopt Houndarr instance {existing.id}"
                )
            claimed_ids.add(existing.id)
            wanted: dict[str, Value] = {
                "name": desired.display_name,
                "type": desired.interface.replace("-", "_"),
                "url": desired.url,
                "api_key": api_key,
                "enabled": desired.enabled,
                **policy_fields,
            }
            identity = {
                "name": existing.name,
                "type": existing.interface.replace("-", "_"),
                "url": existing.url,
                "api_key": existing.api_key,
                "enabled": existing.enabled,
                **existing.values,
            }
            updates = {key: value for key, value in wanted.items() if identity.get(key) != value}
            if existing.url.rstrip("/") == desired.url.rstrip("/"):
                updates.pop("url", None)
            if updates:
                await store.update(existing.id, updates)
                changed += 1
        return changed
    finally:
        await store.close()
