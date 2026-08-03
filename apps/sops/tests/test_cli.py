from __future__ import annotations

import io
from pathlib import Path

import pytest
import yaml

from sops_tools.cli import (
    Application,
    cat_main,
    copy_main,
    edit_main,
    set_main,
    update_main,
)
from sops_tools.repository import RuntimeEnvironment, SecretDomain, SecretRepository

from .fakes import MemorySopsBackend, StaticBackendFactory


def application(
    tmp_path: Path,
    documents: dict[str, object],
    *,
    template: object = None,
) -> tuple[Application, MemorySopsBackend]:
    repository = SecretRepository(tmp_path, SecretDomain("main", None))
    repository.directory.mkdir(parents=True)
    repository.template.write_text(
        yaml.safe_dump({} if template is None else template, sort_keys=False)
    )
    paths = {repository.secret(host): value for host, value in documents.items()}
    for path in paths:
        path.touch()
    backend = MemorySopsBackend(paths)  # type: ignore[arg-type]
    runtime = RuntimeEnvironment(
        repo_root=tmp_path,
        home=tmp_path / "home",
        config_home=tmp_path / "home/.config",
        system_name="Linux",
        hostname="beast",
        values={},
    )
    return Application(runtime, StaticBackendFactory(backend)), backend


def test_cat_defaults_to_current_host(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    current, _ = application(tmp_path, {"beast": {"keep": "value"}})

    assert cat_main(["--domain", "main"], application=current) == 0

    assert "keep: value" in capsys.readouterr().out


def test_edit_only_invokes_sops_editor(tmp_path: Path) -> None:
    current, backend = application(tmp_path, {"beast": {"keep": "value"}})

    assert edit_main(["--domain", "main", "beast"], application=current) == 0

    assert backend.edits == [current.runtime.repo_root / "secrets/main/beast.yaml"]


def test_set_reads_the_exact_value_from_stdin(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    current, backend = application(tmp_path, {"beast": {"keep": "value"}})
    monkeypatch.setattr("sys.stdin", io.StringIO(" secret  \n"))

    assert (
        set_main(
            ["--domain", "main", "beast", "nested/key.with-dash"],
            application=current,
        )
        == 0
    )

    secret = current.runtime.repo_root / "secrets/main/beast.yaml"
    assert backend.documents[secret] == {
        "keep": "value",
        "nested": {"key.with-dash": " secret  \n"},
    }
    assert "Updated beast:nested/key.with-dash." in capsys.readouterr().out


def test_copy_reports_distinct_destination_path(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    current, backend = application(
        tmp_path,
        {"source": {"value": "secret"}, "destination": {"keep": "value"}},
    )

    assert (
        copy_main(
            [
                "--domain",
                "main",
                "source",
                "destination",
                "value",
                "copied/value",
            ],
            application=current,
        )
        == 0
    )

    secret = current.runtime.repo_root / "secrets/main/destination.yaml"
    assert backend.documents[secret] == {
        "keep": "value",
        "copied": {"value": "secret"},
    }
    assert "to destination:copied/value." in capsys.readouterr().out


def test_update_reports_change_and_noop(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    current, _ = application(
        tmp_path,
        {"beast": {"keep": "secret"}},
        template={"keep": "template", "new": "value"},
    )

    assert update_main(["--domain", "main"], application=current) == 0
    assert "Updated secret from templates:" in capsys.readouterr().out

    assert update_main(["--domain", "main"], application=current) == 0
    assert "Secret already up to date:" in capsys.readouterr().out


def test_expected_errors_are_printed_without_a_traceback(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    current, _ = application(tmp_path, {"beast": {}})

    assert cat_main(["--domain", "main", "missing"], application=current) == 1

    captured = capsys.readouterr()
    assert "Secret not found:" in captured.err
    assert "Traceback" not in captured.err
