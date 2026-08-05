import json

import pytest

from flake_input_update_summary import app


def github_lock(revision, owner="example", repo="project"):
    return {
        "lastModified": 1,
        "narHash": f"sha256-{revision}",
        "owner": owner,
        "repo": repo,
        "rev": revision,
        "type": "github",
    }


def lock_data(inputs):
    nodes = {"root": {"inputs": {}}}
    for name, locked in inputs.items():
        node_name = f"node-{name}"
        nodes["root"]["inputs"][name] = node_name
        nodes[node_name] = {"locked": locked}
    return {"nodes": nodes, "root": "root", "version": 7}


def lock(inputs):
    return app.FlakeLock.model_validate(lock_data(inputs))


def locked(value):
    return app.LockedInput.model_validate(value)


def test_renders_updated_inputs_with_compare_links():
    old_revision = "1" * 40
    new_revision = "2" * 40
    unchanged_revision = "3" * 40
    old_lock = lock(
        {
            "nixpkgs": github_lock(old_revision, "NixOS", "nixpkgs"),
            "unchanged": github_lock(unchanged_revision),
        }
    )
    new_lock = lock(
        {
            "nixpkgs": github_lock(new_revision, "NixOS", "nixpkgs"),
            "unchanged": github_lock(unchanged_revision),
        }
    )

    body = app.render_body(old_lock, new_lock, "schedule")

    assert "| Input | Update | Diff |" in body
    assert "| `nixpkgs` | `1111111` → `2222222` |" in body
    assert f"https://github.com/NixOS/nixpkgs/compare/{old_revision}...{new_revision}" in body
    assert "unchanged" not in body
    assert body.endswith("Trigger: schedule\n")


def test_renders_transitive_input_updates_by_path():
    old_data = lock_data({"parent": github_lock("a" * 40)})
    new_data = lock_data({"parent": github_lock("a" * 40)})
    old_data["nodes"]["node-parent"]["inputs"] = {"child": "old-child"}
    new_data["nodes"]["node-parent"]["inputs"] = {"child": "new-child"}
    old_data["nodes"]["old-child"] = {"locked": github_lock("b" * 40)}
    new_data["nodes"]["new-child"] = {"locked": github_lock("c" * 40)}

    body = app.render_body(
        app.FlakeLock.model_validate(old_data),
        app.FlakeLock.model_validate(new_data),
        "workflow_dispatch",
    )

    assert "| `parent/child` | `bbbbbbb` → `ccccccc` |" in body


def test_ignores_follows_aliases_cycles_and_missing_nodes():
    data = lock_data({"parent": github_lock("a" * 40)})
    data["nodes"]["node-parent"]["inputs"] = {
        "follows": ["nixpkgs"],
        "cycle": "root",
        "missing": "absent",
    }
    parsed = app.FlakeLock.model_validate(data)

    body = app.render_body(parsed, parsed, "schedule")

    assert "No flake input revisions changed." in body
    assert "parent/follows" not in body


def test_marks_cross_repository_updates_without_compare_link():
    old_lock = lock({"input": github_lock("a" * 40, repo="old")})
    new_lock = lock({"input": github_lock("b" * 40, repo="new")})

    body = app.render_body(old_lock, new_lock, "schedule")

    assert "| `input` | `aaaaaaa` → `bbbbbbb` | Unavailable |" in body


def test_supports_git_urls_for_github_inputs():
    old_revision = "a" * 40
    new_revision = "b" * 40
    old = locked(
        {
            "rev": old_revision,
            "type": "git",
            "url": "https://github.com/example/project.git",
        }
    )
    new = old.model_copy(update={"rev": new_revision})

    assert app.compare_url(old, new) == (
        f"https://github.com/example/project/compare/{old_revision}...{new_revision}"
    )


def test_supports_gitlab_compare_links():
    old = locked(
        {
            "owner": "example",
            "repo": "project",
            "rev": "a" * 40,
            "type": "gitlab",
        }
    )
    new = old.model_copy(update={"rev": "b" * 40})

    assert app.compare_url(old, new) == (
        f"https://gitlab.com/example/project/-/compare/{'a' * 40}...{'b' * 40}"
    )


@pytest.mark.parametrize(
    ("value", "expected"),
    [
        ({"type": "path", "path": "/src/input"}, "/src/input"),
        ({"type": "tarball", "narHash": "sha256-value"}, "sha256-value"),
        ({"type": "unknown"}, "unknown"),
    ],
)
def test_revision_uses_available_lock_identity(value, expected):
    assert app.revision(locked(value)) == expected


def test_load_lock_rejects_missing_root(tmp_path):
    lock_path = tmp_path / "flake.lock"
    lock_path.write_text(
        json.dumps({"nodes": {}, "root": "root", "version": 7}),
        encoding="utf-8",
    )

    with pytest.raises(app.Error, match="root node 'root' is missing"):
        app.load_lock(lock_path)


def test_main_writes_summary(tmp_path):
    old_lock = tmp_path / "old.lock"
    new_lock = tmp_path / "new.lock"
    output = tmp_path / "summary.md"
    old_lock.write_text(
        json.dumps(lock_data({"nixpkgs": github_lock("a" * 40)})),
        encoding="utf-8",
    )
    new_lock.write_text(
        json.dumps(lock_data({"nixpkgs": github_lock("b" * 40)})),
        encoding="utf-8",
    )

    result = app.main(
        [
            str(old_lock),
            str(new_lock),
            "--trigger",
            "schedule",
            "--output",
            str(output),
        ]
    )

    assert result == 0
    assert "`aaaaaaa` → `bbbbbbb`" in output.read_text(encoding="utf-8")


def test_main_reports_unreadable_lock(tmp_path, capsys):
    with pytest.raises(SystemExit) as raised:
        app.main(
            [
                str(tmp_path / "missing.lock"),
                str(tmp_path / "also-missing.lock"),
                "--trigger",
                "schedule",
                "--output",
                str(tmp_path / "summary.md"),
            ]
        )

    assert raised.value.code == 2
    assert "failed to read" in capsys.readouterr().err
