from __future__ import annotations

from dataclasses import dataclass, field
from uuid import uuid4

import pytest
from jellyfin_tools.polyglot import (
    Alternative,
    Configuration,
    Library,
    Mirror,
    configure,
)
from pydantic import BaseModel


def desired() -> Alternative:
    return Alternative(
        name="Русский",
        language_code="ru-RU",
        metadata_language="ru",
        metadata_country="RU",
        destination_base_path="/media/localized/ru",
        mirrored_libraries=[
            Mirror(
                source_library_name="Movies",
                target_library_name="Фильмы",
                target_path="/media/localized/ru/movies",
            )
        ],
    )


def libraries() -> list[Library]:
    return [
        Library(
            name="Movies",
            item_id=uuid4(),
            locations=["/media/library/movies"],
            collection_type="movies",
        ),
        Library(
            name="Фильмы",
            item_id=uuid4(),
            locations=["/media/localized/ru/movies"],
            collection_type="movies",
        ),
    ]


@dataclass
class Server:
    configuration: Configuration = field(default_factory=Configuration)
    folders: list[Library] = field(default_factory=libraries)
    status: str = "Active"
    writes: int = 0
    sync_requested: bool = False
    task_state: str = "Idle"

    def plugins(self) -> object:
        return [{"Name": "Polyglot", "Id": str(uuid4()), "Status": self.status}]

    def libraries(self) -> object:
        return [library.model_dump(mode="json", by_alias=True) for library in self.folders]

    def plugin_configuration(self, plugin_id: str) -> object:
        return self.configuration.model_dump(mode="json", by_alias=True)

    def update_plugin_configuration(self, plugin_id: str, configuration: BaseModel) -> None:
        assert isinstance(configuration, Configuration)
        self.configuration = configuration
        self.writes += 1

    def tasks(self) -> object:
        return [{"Key": "PolyglotMirrorSync", "Id": "sync", "State": self.task_state}]

    def start_task(self, task_id: str) -> None:
        self.sync_requested = True


def test_registers_existing_libraries_and_disables_user_management() -> None:
    server = Server(configuration=Configuration(auto_manage_new_users=True, user_languages=[{}]))
    configure(server, desired())

    configuration = server.configuration
    assert not configuration.auto_manage_new_users
    assert configuration.user_languages == []
    mirror = configuration.language_alternatives[0].mirrored_libraries[0]
    assert mirror.source_library_id == server.folders[0].item_id
    assert mirror.target_library_id == server.folders[1].item_id
    assert server.sync_requested


def test_repeat_apply_preserves_sync_state_and_does_not_rescan() -> None:
    server = Server()
    configure(server, desired())
    alternative = server.configuration.language_alternatives[0]
    mirror = alternative.mirrored_libraries[0]
    mirror.model_extra.update({"LastSyncedAt": "2026-01-01T00:00:00Z", "Status": "Synced"})
    server.sync_requested = False

    configure(server, desired())

    assert server.writes == 1
    assert not server.sync_requested
    assert server.configuration.language_alternatives[0] == alternative


def test_pending_mirror_retries_initial_sync() -> None:
    server = Server()
    configure(server, desired())
    server.sync_requested = False
    configure(server, desired())
    assert server.writes == 1
    assert server.sync_requested


def test_running_sync_is_not_started_twice() -> None:
    server = Server(task_state="Running")
    configure(server, desired())
    assert not server.sync_requested


@pytest.mark.parametrize("status", ["Restart", "Disabled", "NotSupported"])
def test_inactive_plugin_requires_restart(status: str) -> None:
    server = Server(status=status)
    with pytest.raises(ValueError, match="restart Jellyfin"):
        configure(server, desired())
    assert server.writes == 0


@pytest.mark.parametrize("failure", ["missing", "duplicate", "wrong-path", "wrong-type", "overlap"])
def test_invalid_library_mapping_does_not_change_configuration(failure: str) -> None:
    server = Server()
    if failure == "missing":
        server.folders.pop()
    elif failure == "duplicate":
        server.folders.append(server.folders[0])
    elif failure == "wrong-path":
        server.folders[1].locations = ["/somewhere/else"]
    elif failure == "wrong-type":
        server.folders[1].collection_type = "tvshows"
    else:
        server.folders[0].locations = ["/media"]

    with pytest.raises(ValueError):
        configure(server, desired())
    assert server.writes == 0
    assert not server.sync_requested


def test_unknown_alternative_is_not_discarded() -> None:
    alternative = desired().model_copy(update={"language_code": "es-ES"})
    server = Server(configuration=Configuration(language_alternatives=[alternative]))
    with pytest.raises(ValueError, match="Unexpected Polyglot"):
        configure(server, desired())
    assert server.configuration.language_alternatives == [alternative]


def test_removing_mirror_requires_explicit_cleanup() -> None:
    server = Server()
    configure(server, desired())
    with pytest.raises(ValueError, match="explicit cleanup"):
        configure(server, desired().model_copy(update={"mirrored_libraries": []}))
    assert len(server.configuration.language_alternatives[0].mirrored_libraries) == 1
