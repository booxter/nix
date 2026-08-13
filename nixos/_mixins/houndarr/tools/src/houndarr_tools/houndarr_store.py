from __future__ import annotations

from collections.abc import Callable, Mapping, Sequence
from typing import Protocol, cast

from houndarr.bootstrap import bootstrap_non_web  # type: ignore[import-untyped]
from houndarr.services.instance_validation import (  # type: ignore[import-untyped]
    check_connection,
    type_mismatch_message,
)
from houndarr.services.instances import (  # type: ignore[import-untyped]
    Instance,
    InstanceType,
    create_instance,
    list_instances,
    update_instance,
)

from .models import CurrentInstance, DesiredInstance, Interface, Value


def _instance_type(interface: Interface) -> InstanceType:
    return InstanceType(interface.replace("-", "_"))


def _values(instance: Instance) -> dict[str, Value]:
    return {
        "missing_enabled": instance.missing.missing_enabled,
        "batch_size": instance.missing.batch_size,
        "sleep_interval_mins": instance.missing.sleep_interval_mins,
        "hourly_cap": instance.missing.hourly_cap,
        "cooldown_days": instance.missing.cooldown_days,
        "post_release_grace_hrs": instance.missing.post_release_grace_hrs,
        "missing_hot_retry_window_hrs": instance.missing.missing_hot_retry_window_hrs,
        "missing_hot_retry_interval_hrs": instance.missing.missing_hot_retry_interval_hrs,
        "queue_limit": instance.missing.queue_limit,
        "sonarr_search_mode": str(instance.missing.sonarr_search_mode),
        "lidarr_search_mode": str(instance.missing.lidarr_search_mode),
        "readarr_search_mode": str(instance.missing.readarr_search_mode),
        "whisparr_v2_search_mode": str(instance.missing.whisparr_v2_search_mode),
        "cutoff_enabled": instance.cutoff.cutoff_enabled,
        "cutoff_batch_size": instance.cutoff.cutoff_batch_size,
        "cutoff_cooldown_days": instance.cutoff.cutoff_cooldown_days,
        "cutoff_hourly_cap": instance.cutoff.cutoff_hourly_cap,
        "upgrade_enabled": instance.upgrade.upgrade_enabled,
        "upgrade_batch_size": instance.upgrade.upgrade_batch_size,
        "upgrade_cooldown_days": instance.upgrade.upgrade_cooldown_days,
        "upgrade_hourly_cap": instance.upgrade.upgrade_hourly_cap,
        "upgrade_sonarr_search_mode": str(instance.upgrade.upgrade_sonarr_search_mode),
        "upgrade_lidarr_search_mode": str(instance.upgrade.upgrade_lidarr_search_mode),
        "upgrade_readarr_search_mode": str(instance.upgrade.upgrade_readarr_search_mode),
        "upgrade_whisparr_v2_search_mode": str(instance.upgrade.upgrade_whisparr_v2_search_mode),
        "upgrade_series_window_size": instance.upgrade.upgrade_series_window_size,
        "allowed_time_window": instance.schedule.allowed_time_window,
        "search_order": str(instance.schedule.search_order),
        "tag_filter_include": ",".join(instance.tag_filter.include),
        "tag_filter_exclude": ",".join(instance.tag_filter.exclude),
    }


def _current(instance: Instance) -> CurrentInstance:
    return CurrentInstance(
        id=instance.core.id,
        name=instance.core.name,
        interface=cast(Interface, str(instance.core.type).replace("_", "-")),
        url=instance.core.url,
        api_key=instance.core.api_key,
        enabled=instance.core.enabled,
        values=_values(instance),
    )


class Backend(Protocol):
    async def list(self, master_key: bytes) -> Sequence[Instance]: ...

    async def verify(self, interface: Interface, url: str, api_key: str) -> bool: ...

    async def create(
        self,
        desired: DesiredInstance,
        api_key: str,
        fields: Mapping[str, Value],
        master_key: bytes,
    ) -> None: ...

    async def update(
        self, instance_id: int, fields: Mapping[str, Value], master_key: bytes
    ) -> None: ...


class UpstreamBackend:
    async def list(self, master_key: bytes) -> Sequence[Instance]:
        return cast(Sequence[Instance], await list_instances(master_key=master_key))

    async def verify(self, interface: Interface, url: str, api_key: str) -> bool:
        instance_type = _instance_type(interface)
        result = await check_connection(instance_type, url, api_key)
        return result.reachable and type_mismatch_message(result, instance_type) is None

    async def create(
        self,
        desired: DesiredInstance,
        api_key: str,
        fields: Mapping[str, Value],
        master_key: bytes,
    ) -> None:
        await create_instance(
            name=desired.display_name,
            type=_instance_type(desired.interface),
            url=desired.url,
            api_key=api_key,
            enabled=desired.enabled,
            master_key=master_key,
            **dict(fields),
        )

    async def update(
        self, instance_id: int, fields: Mapping[str, Value], master_key: bytes
    ) -> None:
        await update_instance(instance_id, master_key=master_key, **dict(fields))


class HoundarrStore:
    def __init__(
        self,
        data_dir: str,
        backend: Backend | None = None,
        bootstrap: Callable[[str], tuple[object, object, bytes]] = bootstrap_non_web,
    ) -> None:
        _, _, self.master_key = bootstrap(data_dir)
        self.backend = backend or UpstreamBackend()

    async def list(self) -> tuple[CurrentInstance, ...]:
        instances = await self.backend.list(self.master_key)
        return tuple(_current(instance) for instance in instances)

    async def verify(self, interface: Interface, url: str, api_key: str) -> bool:
        return await self.backend.verify(interface, url, api_key)

    async def create(
        self,
        desired: DesiredInstance,
        api_key: str,
        fields: Mapping[str, Value],
    ) -> None:
        await self.backend.create(desired, api_key, fields, self.master_key)

    async def update(self, instance_id: int, fields: Mapping[str, Value]) -> None:
        await self.backend.update(instance_id, fields, self.master_key)
