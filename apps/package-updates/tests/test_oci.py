from __future__ import annotations

import io
import json
from collections.abc import Mapping, Sequence
from pathlib import Path

import pytest
from pydantic import ValidationError

from package_updates.common import CommandResult, Runner, ToolPaths, UpdateError
from package_updates.models import OciPin, OciPins, PrefetchedImage
from package_updates.oci import (
    CommandOciBackend,
    NixModuleOciPinStore,
    changelog_for,
    image_diff_url,
    latest_tag,
    run,
    selected_pins,
    summary_row,
    update_oci_images,
)


class FakeOciBackend:
    def __init__(self) -> None:
        self.label_requests: list[tuple[str, str, str]] = []

    def list_tags(self, image: str) -> tuple[str, ...]:
        assert image == "docker.io/example/romm"
        return ("latest", "4.9.1", "4.10.0", "4.10.0-beta.1", "5")

    def prefetch(self, image: str, tag: str) -> PrefetchedImage:
        assert (image, tag) == ("docker.io/example/romm", "4.10.0")
        return PrefetchedImage(imageDigest="sha256:new", hash="sha256-newhash")

    def labels(self, image: str, tag: str, digest: str) -> dict[str, str]:
        self.label_requests.append((image, tag, digest))
        revision = "oldrev" if digest == "sha256:old" else "newrev"
        return {
            "org.opencontainers.image.source": "https://github.com/example/romm",
            "org.opencontainers.image.revision": revision,
        }


class FakePinStore:
    def __init__(self) -> None:
        self.saved: list[tuple[str, OciPin]] = []

    def load(self) -> OciPins:
        raise AssertionError("load is not expected")

    def save(self, name: str, pin: OciPin) -> None:
        self.saved.append((name, pin.model_copy(deep=True)))


class OciRunner(Runner):
    def __init__(self) -> None:
        self.calls: list[tuple[str, ...]] = []

    def run(
        self,
        arguments: Sequence[str],
        *,
        cwd: Path,
        environment: Mapping[str, str] | None = None,
        capture: bool = True,
    ) -> CommandResult:
        del cwd, environment, capture
        command = tuple(arguments)
        self.calls.append(command)
        if command[1] == "list-tags":
            return CommandResult(0, '{"Tags":["1.0.0","1.1.0"]}')
        if command[1] == "inspect":
            return CommandResult(
                0,
                json.dumps(
                    {
                        "config": {
                            "Labels": {
                                "org.opencontainers.image.source": (
                                    "https://github.com/example/demo"
                                )
                            }
                        }
                    }
                ),
            )
        if command[0] == "prefetch":
            return CommandResult(0, '{"imageDigest":"sha256:new","hash":"sha256-hash"}')
        return CommandResult(0)


class ModuleRunner(Runner):
    def __init__(self) -> None:
        self.calls: list[tuple[tuple[str, ...], Mapping[str, str] | None]] = []

    def run(
        self,
        arguments: Sequence[str],
        *,
        cwd: Path,
        environment: Mapping[str, str] | None = None,
        capture: bool = True,
    ) -> CommandResult:
        del cwd, capture
        self.calls.append((tuple(arguments), environment))
        if "--json" in arguments:
            target = make_pin().model_dump(mode="json", by_alias=True) | {
                "path": "nixos/_mixins/romm/image-pin.nix"
            }
            return CommandResult(0, json.dumps({"romm": target}))
        assert environment is not None
        rendered = '{ tag = "4.10.0"; }\n'
        return CommandResult(0, rendered)


def make_pin(*, tag: str = "4.9.1") -> OciPin:
    return OciPin.model_validate(
        {
            "image": "docker.io/example/romm",
            "tag": tag,
            "digest": "sha256:old",
            "hash": "sha256-oldhash",
            "tagRegex": r"^[0-9]+\.[0-9]+\.[0-9]+$",
            "changelog": "https://example.invalid/releases/{tag}",
        }
    )


def test_updates_pin_and_writes_summary(tmp_path: Path) -> None:
    pins = OciPins({"romm": make_pin(), "other": make_pin(tag="4.10.0")})
    pin_store = FakePinStore()
    backend = FakeOciBackend()
    summary = tmp_path / "summary.md"
    stdout = io.StringIO()

    update_oci_images(
        pins,
        selected_pins(pins, "romm"),
        pin_store,
        summary,
        backend,
        stdout,
    )

    assert len(pin_store.saved) == 1
    name, updated = pin_store.saved[0]
    assert name == "romm"
    assert updated.tag == "4.10.0"
    assert updated.digest == "sha256:new"
    assert updated.hash == "sha256-newhash"
    assert pins.root["other"].tag == "4.10.0"
    assert (
        "| `romm` | `docker.io/example/romm` | `4.9.1 -> 4.10.0` | "
        "`sha256:old -> sha256:new` | `sha256-oldhash -> sha256-newhash` | "
        "[link](https://example.invalid/releases/4.10.0) | "
        "[compare](https://github.com/example/romm/compare/oldrev...newrev) |"
        in summary.read_text()
    )
    assert "Wrote OCI image update summary" in stdout.getvalue()


def test_same_tag_digest_change_skips_label_lookup(tmp_path: Path) -> None:
    pins = OciPins({"romm": make_pin(tag="4.10.0")})
    pin_store = FakePinStore()
    backend = FakeOciBackend()
    summary = tmp_path / "summary.md"
    update_oci_images(
        pins,
        selected_pins(pins, "romm"),
        pin_store,
        summary,
        backend,
        io.StringIO(),
    )
    assert backend.label_requests == []
    assert "| `romm` | `docker.io/example/romm` | `4.10.0`" in summary.read_text()
    assert "not set |" in summary.read_text()


def test_tag_selection_uses_natural_order_and_reports_bad_filters() -> None:
    tags = ("4.9.1", "4.10.0", "4.10.0-beta.1", "latest")
    assert latest_tag("example", r"^[0-9]+\.[0-9]+\.[0-9]+$", tags) == "4.10.0"
    with pytest.raises(UpdateError, match="No tags"):
        latest_tag("example", r"^v", tags)
    with pytest.raises(UpdateError, match="Invalid tag regex"):
        latest_tag("example", "[", tags)


def test_pins_are_selected_and_validated() -> None:
    pins = OciPins({"romm": make_pin()})
    assert selected_pins(pins, "romm")[0][0] == "romm"
    with pytest.raises(UpdateError, match="No OCI image targets matched"):
        selected_pins(pins, "missing")
    with pytest.raises(ValidationError):
        OciPins.model_validate({"broken": {"tag": "1.0.0"}})


def test_diff_falls_back_to_changelog_and_summary_helpers() -> None:
    class EmptyLabels(FakeOciBackend):
        def labels(self, image: str, tag: str, digest: str) -> dict[str, str]:
            return {}

    pin = make_pin()
    pin.changelog = "https://github.com/example/romm/releases/tag/{tag}"
    assert image_diff_url(EmptyLabels(), pin.image, pin, "4.10.0", "sha256:new") == (
        "https://github.com/example/romm/compare/4.9.1...4.10.0"
    )
    assert changelog_for("https://example/{tag}/{tag}", "v1") == "https://example/v1/v1"
    assert "`4.9.1 -> new`" in summary_row("demo", pin, "new", "digest", "hash", None)


def test_command_backend_parses_registry_boundaries(tmp_path: Path) -> None:
    runner = OciRunner()
    tools = ToolPaths(
        nix="nix",
        nix_update="nix-update",
        nix_prefetch_docker="prefetch",
        skopeo="skopeo",
        select_nodejs="select-nodejs",
    )
    backend = CommandOciBackend(tmp_path, tools, runner)
    assert backend.list_tags("example/demo") == ("1.0.0", "1.1.0")
    assert backend.prefetch("example/demo", "1.1.0").image_digest == "sha256:new"
    assert (
        backend.labels("example/demo", "1.1.0", "sha256:new")["org.opencontainers.image.source"]
        == "https://github.com/example/demo"
    )


def test_nix_module_store_loads_targets_and_renders_owned_pin(tmp_path: Path) -> None:
    (tmp_path / "apps" / "package-updates").mkdir(parents=True)
    (tmp_path / "apps" / "package-updates" / "oci-targets.nix").write_text("{}\n")
    (tmp_path / "nixos" / "_mixins" / "romm").mkdir(parents=True)
    pins_path = tmp_path / "nixos" / "_mixins" / "romm" / "image-pin.nix"
    pins_path.write_text("{}\n")
    runner = ModuleRunner()
    store = NixModuleOciPinStore(tmp_path, "nix", runner)

    pins = store.load()
    assert pins.root["romm"].tag == "4.9.1"
    pins.root["romm"].tag = "4.10.0"
    store.save("romm", pins.root["romm"])

    assert pins_path.read_text() == '{ tag = "4.10.0"; }\n'
    assert runner.calls[0][0] == (
        "nix",
        "eval",
        "--json",
        "--file",
        "apps/package-updates/oci-targets.nix",
    )
    render_call, environment = runner.calls[1]
    assert render_call[:4] == ("nix", "eval", "--impure", "--raw")
    assert environment is not None
    assert environment["OCI_IMAGE_REPO_ROOT"] == str(tmp_path)
    assert not Path(environment["OCI_IMAGE_PIN_JSON"]).exists()


def test_console_entrypoint_lists_module_targets(tmp_path: Path) -> None:
    (tmp_path / ".git").mkdir()
    (tmp_path / "flake.nix").touch()
    stdout = io.StringIO()

    assert run(["--list-targets"], cwd=tmp_path, runner=ModuleRunner(), stdout=stdout) == 0
    assert stdout.getvalue() == "romm\tdocker.io/example/romm:4.9.1\n"


def test_console_entrypoint_reports_missing_target(tmp_path: Path) -> None:
    (tmp_path / ".git").mkdir()
    (tmp_path / "flake.nix").touch()
    stderr = io.StringIO()

    assert run(["--target", "missing"], cwd=tmp_path, runner=ModuleRunner(), stderr=stderr) == 1
    assert "No OCI image targets matched" in stderr.getvalue()
