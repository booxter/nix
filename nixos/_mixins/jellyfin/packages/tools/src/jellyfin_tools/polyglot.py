"""Connect Jellarr-created libraries to Polyglot without giving it user policies."""

from __future__ import annotations

import argparse
import os
from datetime import UTC, datetime
from pathlib import Path
from typing import Protocol
from uuid import UUID, uuid4

from pydantic import BaseModel, ConfigDict, Field, TypeAdapter
from pydantic.alias_generators import to_pascal

from .api import JellyfinApi


class ApiModel(BaseModel):
    model_config = ConfigDict(alias_generator=to_pascal, populate_by_name=True, extra="allow")


class Mirror(ApiModel):
    id: UUID = Field(default_factory=uuid4)
    source_library_name: str
    target_library_name: str
    target_path: str
    source_library_id: UUID | None = None
    target_library_id: UUID | None = None
    collection_type: str | None = None


class Alternative(ApiModel):
    id: UUID = Field(default_factory=uuid4)
    name: str
    language_code: str
    metadata_language: str
    metadata_country: str
    destination_base_path: str
    mirrored_libraries: list[Mirror]
    created_at: datetime = Field(default_factory=lambda: datetime.now(UTC))


class Configuration(ApiModel):
    language_alternatives: list[Alternative] = Field(default_factory=list)
    auto_manage_new_users: bool = False
    user_languages: list[object] = Field(default_factory=list)
    sync_mirrors_after_library_scan: bool = True


class Library(ApiModel):
    name: str
    item_id: UUID
    locations: list[str]
    collection_type: str


class Plugin(ApiModel):
    name: str
    id: UUID
    status: str


class Task(ApiModel):
    key: str
    id: str
    state: str


class Api(Protocol):
    def plugins(self) -> object: ...

    def libraries(self) -> object: ...

    def plugin_configuration(self, plugin_id: str) -> object: ...

    def update_plugin_configuration(self, plugin_id: str, configuration: BaseModel) -> None: ...

    def tasks(self) -> object: ...

    def start_task(self, task_id: str) -> None: ...


def find_library(libraries: list[Library], name: str) -> Library:
    matches = [library for library in libraries if library.name == name]
    if len(matches) != 1:
        raise ValueError(f"Expected exactly one Jellyfin library named {name!r}")
    return matches[0]


def resolve_mirror(desired: Mirror, libraries: list[Library]) -> Mirror:
    source = find_library(libraries, desired.source_library_name)
    target = find_library(libraries, desired.target_library_name)
    target_path = Path(desired.target_path)
    if target.locations != [str(target_path)] or source.collection_type != target.collection_type:
        raise ValueError(f"Mirror library has unexpected paths or type: {target.name}")
    for location in source.locations:
        source_path = Path(location)
        if target_path.is_relative_to(source_path) or source_path.is_relative_to(target_path):
            raise ValueError(f"Source and mirror paths overlap: {source.name}")
    return desired.model_copy(
        update={
            "source_library_id": source.item_id,
            "target_library_id": target.item_id,
            "collection_type": source.collection_type,
        }
    )


def reconcile(
    current: Configuration, desired: Alternative, libraries: list[Library]
) -> Configuration:
    existing = next(
        (
            item
            for item in current.language_alternatives
            if item.language_code == desired.language_code
        ),
        None,
    )
    # This installation has one declarative language alternative. Refuse to discard
    # unknown alternatives, which could leave unmanaged libraries and hardlinks.
    if len(current.language_alternatives) > (1 if existing else 0):
        raise ValueError("Unexpected Polyglot language alternatives; reconcile them explicitly")

    mirrors = []
    for item in desired.mirrored_libraries:
        resolved = resolve_mirror(item, libraries)
        previous = (
            next(
                (
                    mirror
                    for mirror in existing.mirrored_libraries
                    if mirror.target_library_id == resolved.target_library_id
                ),
                None,
            )
            if existing
            else None
        )
        if previous:
            # Keep Polyglot's sync status, timestamps, and stable mirror ID.
            resolved = previous.model_copy(update=resolved.model_dump(exclude={"id"}))
        mirrors.append(resolved)

    alternative = desired.model_copy(update={"mirrored_libraries": mirrors})
    if existing:
        if {mirror.target_library_id for mirror in existing.mirrored_libraries} - {
            mirror.target_library_id for mirror in mirrors
        }:
            raise ValueError("Removing Polyglot mirrors requires explicit cleanup")
        alternative = alternative.model_copy(
            update={"id": existing.id, "created_at": existing.created_at}
        )

    return current.model_copy(
        update={
            "language_alternatives": [alternative],
            "auto_manage_new_users": False,
            "user_languages": [],
            "sync_mirrors_after_library_scan": True,
        }
    )


def configure(api: Api, desired: Alternative) -> None:
    plugins = TypeAdapter(list[Plugin]).validate_python(api.plugins())
    plugin = next((plugin for plugin in plugins if plugin.name == "Polyglot"), None)
    if plugin is None or plugin.status != "Active":
        raise ValueError("Polyglot is not active; restart Jellyfin after Jellarr installs it")

    current = Configuration.model_validate(api.plugin_configuration(str(plugin.id)))
    libraries = TypeAdapter(list[Library]).validate_python(api.libraries())
    updated = reconcile(current, desired, libraries)
    if updated != current:
        api.update_plugin_configuration(str(plugin.id), updated)

    # Queue the initial population asynchronously; later syncs belong to Polyglot.
    # Retry pending mirrors on the next Jellarr run if the task failed to start.
    pending = any(
        not mirror.model_extra or not mirror.model_extra.get("LastSyncedAt")
        for mirror in updated.language_alternatives[0].mirrored_libraries
    )
    if updated != current or pending:
        tasks = TypeAdapter(list[Task]).validate_python(api.tasks())
        task = next(task for task in tasks if task.key == "PolyglotMirrorSync")
        if task.state == "Idle":
            api.start_task(task.id)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", required=True)
    parser.add_argument("--config", required=True, type=Path)
    args = parser.parse_args()
    desired = Alternative.model_validate_json(args.config.read_text())
    configure(JellyfinApi(args.url, os.environ["JELLARR_API_KEY"]), desired)
