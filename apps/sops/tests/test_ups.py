from __future__ import annotations

import json
from pathlib import Path

import pytest

from sops_tools.errors import ToolError
from sops_tools.repository import SecretDomain, SecretRepository
from sops_tools.secrets import SecretService
from sops_tools.ups import UpsInventory, UpsService

from .fakes import MemorySopsBackend


def inventory(tmp_path: Path, value: object) -> UpsInventory:
    path = tmp_path / "ups.json"
    path.write_text(json.dumps(value))
    return UpsInventory.load(path)


def service(tmp_path: Path) -> tuple[UpsService, MemorySopsBackend]:
    repository = SecretRepository(tmp_path, SecretDomain("main", None))
    repository.directory.mkdir(parents=True)
    documents = {
        repository.secret("ups"): {
            "nut": {"users": {"upsslave": {"password": "secret"}}}
        },
        repository.secret("fana"): {"keep": "fana"},
        repository.secret("gw"): {"keep": "gw"},
    }
    for path in documents:
        path.touch()
    backend = MemorySopsBackend(documents)
    return (
        UpsService(
            SecretService(repository, backend),
            inventory(tmp_path, {"ups": ["fana", "gw"]}),
        ),
        backend,
    )


def test_default_clients_come_from_inventory(tmp_path: Path) -> None:
    ups, backend = service(tmp_path)

    assert ups.sync_server("ups") == ("fana", "gw")

    for client in ("fana", "gw"):
        document = backend.documents[ups.secrets.repository.secret(client)]
        assert document["nut"] == {"monitors": {"ups": {"password": "secret"}}}


def test_explicit_clients_override_inventory(tmp_path: Path) -> None:
    ups, backend = service(tmp_path)

    assert ups.sync_server("ups", ("gw",)) == ("gw",)

    assert "nut" not in backend.documents[ups.secrets.repository.secret("fana")]


def test_empty_inventory_selection_is_a_noop(tmp_path: Path) -> None:
    ups, backend = service(tmp_path)
    before = backend.documents.copy()

    assert ups.sync_server("unknown") == ()
    assert backend.documents == before


def test_inventory_rejects_wrong_shapes(tmp_path: Path) -> None:
    with pytest.raises(ToolError, match="Invalid UPS client inventory"):
        inventory(tmp_path, {"ups": "fana"})
