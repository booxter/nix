from __future__ import annotations

from pathlib import Path

from sops_tools.model import KeyPath
from sops_tools.repository import SecretDomain, SecretRepository
from sops_tools.secrets import CommandSopsBackend, SecretService

from .fakes import MemorySopsBackend, RecordingRunner


def service(
    tmp_path: Path,
    documents: dict[str, object],
    *,
    template: str = "{}\n",
    host_template: str | None = None,
) -> tuple[SecretService, MemorySopsBackend]:
    repository = SecretRepository(tmp_path, SecretDomain("main", None))
    repository.directory.mkdir(parents=True)
    repository.template.write_text(template)
    paths = {repository.secret(host): value for host, value in documents.items()}
    for path in paths:
        path.touch()
    if host_template is not None:
        template_path = repository.host_template("beast")
        template_path.parent.mkdir()
        template_path.write_text(host_template)
    backend = MemorySopsBackend(paths)  # type: ignore[arg-type]
    return SecretService(repository, backend), backend


def test_set_preserves_exact_text_and_literal_path(tmp_path: Path) -> None:
    secrets, backend = service(tmp_path, {"beast": {"keep": "value"}})
    value = " leading\ntrailing spaces   \n"

    secrets.set_text("beast", KeyPath.parse("nested/key.with-dashes"), value)

    assert backend.documents[secrets.repository.secret("beast")] == {
        "keep": "value",
        "nested": {"key.with-dashes": value},
    }


def test_copy_supports_different_paths_and_complex_values(tmp_path: Path) -> None:
    secrets, backend = service(
        tmp_path,
        {
            "source": {"attic": {"token": "secret", "endpoint": "cache"}},
            "destination": {"keep": "destination"},
        },
    )

    secrets.copy(
        "source",
        "destination",
        KeyPath.parse("attic"),
        KeyPath.parse("copied/attic"),
    )

    assert backend.documents[secrets.repository.secret("destination")] == {
        "keep": "destination",
        "copied": {"attic": {"token": "secret", "endpoint": "cache"}},
    }


def test_update_adds_default_and_host_template_leaves(tmp_path: Path) -> None:
    secrets, backend = service(
        tmp_path,
        {"beast": {"common": {"shared": "secret"}, "keep": "value"}},
        template="common:\n  shared: template\nattic:\n  token: replace\n",
        host_template="jellyfin:\n  apiKey: replace\n",
    )

    result = secrets.update("beast")

    assert result.changed and not result.reencrypted
    assert backend.documents[secrets.repository.secret("beast")] == {
        "common": {"shared": "secret"},
        "keep": "value",
        "attic": {"token": "replace"},
        "jellyfin": {"apiKey": "replace"},
    }
    assert [call[1].display() for call in backend.set_calls] == [
        "attic/token",
        "jellyfin/apiKey",
    ]


def test_update_is_a_true_noop_when_converged(tmp_path: Path) -> None:
    secrets, backend = service(
        tmp_path,
        {"beast": {"present": "secret"}},
        template="present: template\n",
    )

    result = secrets.update("beast")

    assert not result.changed
    assert backend.set_calls == []
    assert backend.encryptions == []


def test_force_update_reencrypts_without_changing_values(tmp_path: Path) -> None:
    secrets, backend = service(
        tmp_path,
        {"beast": {"present": "secret"}},
        template="present: template\n",
    )

    result = secrets.update("beast", force=True)

    assert result.changed and result.reencrypted
    assert backend.encryptions == [
        (secrets.repository.secret("beast"), {"present": "secret"})
    ]


def test_empty_template_container_uses_full_reencryption(tmp_path: Path) -> None:
    secrets, backend = service(
        tmp_path,
        {"beast": {"present": "secret"}},
        template="present: template\nempty: {}\n",
    )

    result = secrets.update("beast")

    assert result.reencrypted
    assert backend.documents[secrets.repository.secret("beast")] == {
        "present": "secret",
        "empty": {},
    }


def test_command_backend_passes_json_on_stdin_not_argv(tmp_path: Path) -> None:
    runner = RecordingRunner()
    backend = CommandSopsBackend(runner)
    secret = tmp_path / "secret.yaml"

    backend.set_value(secret, KeyPath.parse("nested/value"), "secret\n")

    argv, input_text, _ = runner.calls[0]
    assert argv[-1] == '["nested"]["value"]'
    assert "secret" not in argv
    assert input_text == '"secret\\n"'
