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
    changelog_for,
    image_diff_url,
    latest_tag,
    load_pins,
    main,
    selected_pins,
    summary_row,
    update_oci_images,
    verify_signature,
)


class FakeOciBackend:
    def __init__(self, *, verify_fails: bool = False) -> None:
        self.verify_fails = verify_fails
        self.verified: list[tuple[str, str, Path]] = []
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

    def verify_signature(self, image: str, digest: str, key: Path) -> None:
        self.verified.append((image, digest, key))
        if self.verify_fails:
            raise UpdateError(f"Cosign verification failed for {image}@{digest}")


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


def make_pin(*, signed: bool = True, tag: str = "4.9.1") -> OciPin:
    signature = (
        {"type": "cosign-key", "key": "apps/package-updates/fixtures/oci-cosign.pub"}
        if signed
        else {}
    )
    return OciPin.model_validate(
        {
            "image": "docker.io/example/romm",
            "tag": tag,
            "digest": "sha256:old",
            "hash": "sha256-oldhash",
            "tagRegex": r"^[0-9]+\.[0-9]+\.[0-9]+$",
            "changelog": "https://example.invalid/releases/{tag}",
            "signature": signature,
        }
    )


def test_updates_signed_pin_after_verification_and_writes_summary(tmp_path: Path) -> None:
    key = tmp_path / "apps/package-updates/fixtures/oci-cosign.pub"
    key.parent.mkdir(parents=True)
    key.write_text("public key")
    pins_file = tmp_path / "oci-images.json"
    pins = OciPins({"romm": make_pin(), "other": make_pin(signed=False, tag="4.10.0")})
    pins_file.write_text(json.dumps(pins.model_dump(mode="json", by_alias=True)))
    backend = FakeOciBackend()
    summary = tmp_path / "summary.md"
    stdout = io.StringIO()

    update_oci_images(
        pins,
        selected_pins(pins, "romm"),
        pins_file,
        summary,
        tmp_path,
        backend,
        stdout,
    )

    updated = json.loads(pins_file.read_text())
    assert updated["romm"]["tag"] == "4.10.0"
    assert updated["romm"]["digest"] == "sha256:new"
    assert updated["romm"]["hash"] == "sha256-newhash"
    assert updated["other"]["tag"] == "4.10.0"
    assert backend.verified == [("docker.io/example/romm", "sha256:new", key)]
    assert (
        "| `romm` | `docker.io/example/romm` | `4.9.1 -> 4.10.0` | "
        "`sha256:old -> sha256:new` | `sha256-oldhash -> sha256-newhash` | "
        "[link](https://example.invalid/releases/4.10.0) | "
        "[compare](https://github.com/example/romm/compare/oldrev...newrev) | "
        "`cosign verified` |" in summary.read_text()
    )
    assert "Wrote OCI image update summary" in stdout.getvalue()


def test_same_tag_digest_change_skips_label_lookup(tmp_path: Path) -> None:
    pins = OciPins({"romm": make_pin(signed=False, tag="4.10.0")})
    pins_file = tmp_path / "pins.json"
    pins_file.write_text(json.dumps(pins.model_dump(mode="json", by_alias=True)))
    backend = FakeOciBackend()
    summary = tmp_path / "summary.md"
    update_oci_images(
        pins,
        selected_pins(pins, "romm"),
        pins_file,
        summary,
        tmp_path,
        backend,
        io.StringIO(),
    )
    assert backend.label_requests == []
    assert "| `romm` | `docker.io/example/romm` | `4.10.0`" in summary.read_text()
    assert "not set | `not configured`" in summary.read_text()


def test_signature_failure_does_not_rewrite_pin(tmp_path: Path) -> None:
    key = tmp_path / "apps/package-updates/fixtures/oci-cosign.pub"
    key.parent.mkdir(parents=True)
    key.write_text("public key")
    pins = OciPins({"romm": make_pin()})
    pins_file = tmp_path / "pins.json"
    original = json.dumps(pins.model_dump(mode="json", by_alias=True))
    pins_file.write_text(original)
    with pytest.raises(UpdateError, match="Cosign verification failed"):
        update_oci_images(
            pins,
            selected_pins(pins, "romm"),
            pins_file,
            tmp_path / "summary.md",
            tmp_path,
            FakeOciBackend(verify_fails=True),
            io.StringIO(),
        )
    assert pins_file.read_text() == original


def test_signature_configuration_rejects_remote_missing_and_unknown_keys(tmp_path: Path) -> None:
    backend = FakeOciBackend()
    remote = make_pin()
    remote.signature.key = "https://example.invalid/key.pub"
    with pytest.raises(UpdateError, match="vendored local path"):
        verify_signature(backend, tmp_path, remote, "sha256:new")
    missing = make_pin()
    missing.signature.key = None
    with pytest.raises(UpdateError, match="missing signature.key"):
        verify_signature(backend, tmp_path, missing, "sha256:new")
    unknown = make_pin()
    unknown.signature.type = "keyless"
    with pytest.raises(UpdateError, match="Unsupported signature"):
        verify_signature(backend, tmp_path, unknown, "sha256:new")
    absent = make_pin(signed=False)
    assert verify_signature(backend, tmp_path, absent, "sha256:new") == "not configured"


def test_tag_selection_uses_natural_order_and_reports_bad_filters() -> None:
    tags = ("4.9.1", "4.10.0", "4.10.0-beta.1", "latest")
    assert latest_tag("example", r"^[0-9]+\.[0-9]+\.[0-9]+$", tags) == "4.10.0"
    with pytest.raises(UpdateError, match="No tags"):
        latest_tag("example", r"^v", tags)
    with pytest.raises(UpdateError, match="Invalid tag regex"):
        latest_tag("example", "[", tags)


def test_pins_are_loaded_selected_and_validated(tmp_path: Path) -> None:
    path = tmp_path / "pins.json"
    path.write_text(json.dumps({"romm": make_pin().model_dump(mode="json", by_alias=True)}))
    pins = load_pins(path)
    assert selected_pins(pins, "romm")[0][0] == "romm"
    with pytest.raises(UpdateError, match="No OCI image targets matched"):
        selected_pins(pins, "missing")
    with pytest.raises(ValidationError):
        OciPins.model_validate({"broken": {"tag": "1.0.0"}})


def test_diff_falls_back_to_changelog_and_summary_helpers() -> None:
    class EmptyLabels(FakeOciBackend):
        def labels(self, image: str, tag: str, digest: str) -> dict[str, str]:
            return {}

    pin = make_pin(signed=False)
    pin.changelog = "https://github.com/example/romm/releases/tag/{tag}"
    assert image_diff_url(EmptyLabels(), pin.image, pin, "4.10.0", "sha256:new") == (
        "https://github.com/example/romm/compare/4.9.1...4.10.0"
    )
    assert changelog_for("https://example/{tag}/{tag}", "v1") == "https://example/v1/v1"
    assert "`4.9.1 -> new`" in summary_row("demo", pin, "new", "digest", "hash", None, "ok")


def test_command_backend_parses_registry_boundaries(tmp_path: Path) -> None:
    runner = OciRunner()
    tools = ToolPaths(
        nix="nix",
        nix_update="nix-update",
        nix_prefetch_docker="prefetch",
        skopeo="skopeo",
        cosign="cosign",
        select_nodejs="select-nodejs",
    )
    backend = CommandOciBackend(tmp_path, tools, runner)
    assert backend.list_tags("example/demo") == ("1.0.0", "1.1.0")
    assert backend.prefetch("example/demo", "1.1.0").image_digest == "sha256:new"
    assert (
        backend.labels("example/demo", "1.1.0", "sha256:new")["org.opencontainers.image.source"]
        == "https://github.com/example/demo"
    )
    key = tmp_path / "key.pub"
    key.write_text("key")
    backend.verify_signature("example/demo", "sha256:new", key)
    assert runner.calls[-1] == (
        "cosign",
        "verify",
        "--key",
        str(key),
        "example/demo@sha256:new",
    )


def test_console_entrypoint_lists_targets(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    (tmp_path / ".git").mkdir()
    (tmp_path / "flake.nix").touch()
    pins_file = tmp_path / "pins.json"
    pins_file.write_text(json.dumps({"romm": make_pin().model_dump(mode="json", by_alias=True)}))
    monkeypatch.chdir(tmp_path)
    assert main(["--pins-file", str(pins_file), "--list-targets"]) == 0
    assert capsys.readouterr().out == "romm\tdocker.io/example/romm:4.9.1\n"


def test_console_entrypoint_reports_missing_target(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    (tmp_path / ".git").mkdir()
    (tmp_path / "flake.nix").touch()
    pins_file = tmp_path / "pins.json"
    pins_file.write_text(json.dumps({"romm": make_pin().model_dump(mode="json", by_alias=True)}))
    monkeypatch.chdir(tmp_path)
    assert main(["--pins-file", str(pins_file), "--target", "missing"]) == 1
    assert "No OCI image targets matched" in capsys.readouterr().err
