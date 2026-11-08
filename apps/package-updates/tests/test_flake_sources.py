from __future__ import annotations

import shutil
from collections.abc import Mapping, Sequence
from pathlib import Path

import pytest
from package_updates.common import CommandResult, SubprocessRunner, ToolPaths, checked
from package_updates.models import PackageTarget
from package_updates.packages import CommandPackageBackend


class LocalStoreRunner(SubprocessRunner):
    def __init__(self, directory: Path) -> None:
        self.environment = {
            "NIX_REMOTE": "local",
            "NIX_STORE_DIR": str(directory / "store"),
            "NIX_STATE_DIR": str(directory / "state"),
            "NIX_LOG_DIR": str(directory / "log"),
            "NIX_CONF_DIR": str(directory / "conf"),
            "XDG_CACHE_HOME": str(directory / "cache"),
            "NIX_CONFIG": (
                "experimental-features = nix-command flakes\n"
                "build-users-group =\n"
                "flake-registry =\n"
            ),
        }

    def run(
        self,
        arguments: Sequence[str],
        *,
        cwd: Path,
        environment: Mapping[str, str] | None = None,
        capture: bool = True,
    ) -> CommandResult:
        return super().run(
            arguments,
            cwd=cwd,
            environment=dict(environment or {}) | self.environment,
            capture=capture,
        )


@pytest.fixture
def checkout(tmp_path: Path) -> tuple[Path, LocalStoreRunner]:
    repo = tmp_path / "repo"
    repo.mkdir()
    runner = LocalStoreRunner(tmp_path / "nix")
    (repo / "flake.nix").write_text(
        """{
  outputs = { self }: {
    updatePackages.x86_64-linux.demo = {
      name = "demo-1.0.0";
      version = "1.0.0";
      src = null;
      passthru.updateScript = [ ./update.sh ];
    };
  };
}
"""
    )
    script = repo / "update.sh"
    shell = shutil.which("sh")
    assert shell is not None
    script.write_text(f'#!{shell}\nprintf "%s" "$UPDATE_NIX_ATTR_PATH" > updated\n')
    script.chmod(0o755)
    checked(runner.run(["git", "init", "-q", str(repo)], cwd=repo), "initializing fixture")
    checked(runner.run(["git", "add", "flake.nix", "update.sh"], cwd=repo), "tracking fixture")
    return repo, runner


def test_checkout_script_is_available_to_the_updater(
    checkout: tuple[Path, LocalStoreRunner],
) -> None:
    repo, runner = checkout
    backend = CommandPackageBackend(repo, ToolPaths.from_environment(), runner)

    backend.update(PackageTarget(attr="demo"))

    assert (repo / "updated").read_text() == "updatePackages.x86_64-linux.demo"


def test_nix_update_can_evaluate_each_edited_snapshot(
    checkout: tuple[Path, LocalStoreRunner],
) -> None:
    repo, runner = checkout
    flake = repo / "flake.nix"
    flake.write_text(flake.read_text().replace("[ ./update.sh ]", "null"))
    backend = CommandPackageBackend(repo, ToolPaths.from_environment(), runner)
    target = PackageTarget(attr="demo", nixUpdateArgs=["--version=skip"])
    for version in ("1.0.0", "2.0.0"):
        flake.write_text(flake.read_text().replace("1.0.0", version))
        result = runner.run(
            ["nix-update", "--flake", "--version=skip", "updatePackages.x86_64-linux.demo"],
            cwd=repo,
        )
        checked(result, f"evaluating the {version} snapshot")
        backend.update(target)
        assert backend.metadata(target).version == version
