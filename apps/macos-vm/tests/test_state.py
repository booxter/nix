import shutil
from pathlib import Path

import pytest
from fleet_macos_vm.state import (
    Bootstrap,
    Guest,
    Image,
    Instance,
    NixBase,
    State,
    clone_guest,
    ensure_base,
    lock,
    run_vm,
)

IMAGE = Image(
    version="27.2", build="test", url="https://example.invalid/os.ipsw", sha256="a" * 64, recipe=1
)
BOOTSTRAP = Bootstrap(installer=Path("/nix/store/test-installer"), version="2.30", recipe=1)


class FakeHypervisor:
    def __init__(self) -> None:
        self.disks: dict[str, dict[str, str]] = {}
        self.preparations = 0
        self.nix_preparations = 0
        self.fail_prepare = False
        self.fail_nix = False
        self.fail_clone = False

    def exists(self, guest: Guest) -> bool:
        return guest.name in self.disks

    def delete(self, guest: Guest) -> None:
        del self.disks[guest.name]

    def prepare_base(self, guest: Guest, image: Image) -> None:
        self.preparations += 1
        self.disks[guest.name] = {"version": image.version}
        (guest.credentials / "key").write_text("dedicated VM key")
        if self.fail_prepare:
            raise RuntimeError("first boot failed")

    def prepare_nix(self, guest: Guest, bootstrap: Bootstrap) -> None:
        self.nix_preparations += 1
        self.disks[guest.name]["nix"] = bootstrap.version
        if self.fail_nix:
            raise RuntimeError("Nix preparation failed")

    def clone(self, base: Guest, guest: Guest) -> None:
        self.disks[guest.name] = self.disks[base.name].copy()
        if self.fail_clone:
            raise RuntimeError("clone interrupted")

    def run(self, guest: Guest, *, gui: bool, nix: bool) -> int:
        assert (guest.credentials / "key").read_text() == "dedicated VM key"
        assert nix == ("nix" in self.disks[guest.name])
        return 0


def launch(
    state: State,
    backend: FakeHypervisor,
    *,
    reset: bool = False,
    image: Image = IMAGE,
    bootstrap: Bootstrap = BOOTSTRAP,
) -> int:
    return run_vm(state, backend, image, bootstrap, gui=False, reset=reset)


def test_resume_preserves_work_and_reset_reuses_the_base(tmp_path: Path) -> None:
    state = State(tmp_path / "state", tmp_path / "checkout")
    backend = FakeHypervisor()
    assert launch(state, backend) == 0
    backend.disks[state.instance.name]["user-file"] = "keep me"

    launch(state, backend)
    assert backend.disks[state.instance.name]["user-file"] == "keep me"
    launch(state, backend, reset=True)
    assert "user-file" not in backend.disks[state.instance.name]
    assert backend.preparations == 1
    assert backend.nix_preparations == 1
    assert backend.disks[state.instance.name]["nix"] == BOOTSTRAP.version


def test_worktrees_share_base_but_have_separate_disks(tmp_path: Path) -> None:
    first = State(tmp_path / "state", tmp_path / "one")
    second = State(first.root, tmp_path / "two")
    backend = FakeHypervisor()
    launch(first, backend)
    backend.disks[first.instance.name]["user-file"] = "private"
    launch(second, backend)
    assert "user-file" not in backend.disks[second.instance.name]
    assert backend.preparations == 1
    assert backend.nix_preparations == 1


def test_pin_change_only_applies_after_reset(tmp_path: Path) -> None:
    state = State(tmp_path / "state", tmp_path / "checkout")
    backend = FakeHypervisor()
    launch(state, backend)
    updated = IMAGE.model_copy(update={"version": "27.3", "sha256": "b" * 64})
    launch(state, backend, image=updated)
    assert backend.disks[state.instance.name]["version"] == "27.2"
    launch(state, backend, reset=True, image=updated)
    assert backend.disks[state.instance.name]["version"] == "27.3"
    assert backend.preparations == 2
    assert backend.nix_preparations == 2


@pytest.mark.parametrize(
    "updated",
    [
        BOOTSTRAP.model_copy(update={"version": "2.31"}),
        BOOTSTRAP.model_copy(update={"recipe": 2}),
        BOOTSTRAP.model_copy(update={"installer": Path("/nix/store/other-installer")}),
    ],
)
def test_bootstrap_change_only_applies_after_reset_without_restoring_macos(
    tmp_path: Path, updated: Bootstrap
) -> None:
    state = State(tmp_path / "state", tmp_path / "checkout")
    backend = FakeHypervisor()
    launch(state, backend)
    launch(state, backend, bootstrap=updated)
    assert backend.disks[state.instance.name]["nix"] == "2.30"
    launch(state, backend, reset=True, bootstrap=updated)
    assert backend.disks[state.instance.name]["nix"] == updated.version
    assert backend.preparations == 1
    assert backend.nix_preparations == 2


def test_existing_macos_only_instance_is_preserved_until_reset(tmp_path: Path) -> None:
    state = State(tmp_path / "state", tmp_path / "checkout")
    backend = FakeHypervisor()
    base = ensure_base(state, backend, IMAGE)
    clone_guest(backend, base, state.instance)
    (state.instance.directory / "ready.json").write_text(Instance(base=IMAGE.key).model_dump_json())
    backend.disks[state.instance.name]["user-file"] = "keep me"

    launch(state, backend)
    assert backend.disks[state.instance.name]["user-file"] == "keep me"
    assert "nix" not in backend.disks[state.instance.name]
    assert backend.nix_preparations == 0

    launch(state, backend, reset=True)
    assert backend.disks[state.instance.name]["nix"] == BOOTSTRAP.version
    assert backend.preparations == 1


def test_failed_nix_preparation_is_retried_without_restoring_macos(tmp_path: Path) -> None:
    state = State(tmp_path / "state", tmp_path / "checkout")
    backend = FakeHypervisor()
    backend.fail_nix = True
    with pytest.raises(RuntimeError, match="Nix preparation failed"):
        launch(state, backend)
    assert not (state.nix_base(IMAGE, BOOTSTRAP).directory / "ready.json").exists()
    backend.fail_nix = False
    launch(state, backend)
    assert backend.preparations == 1
    assert backend.nix_preparations == 2


def test_failed_base_is_not_reused(tmp_path: Path) -> None:
    state = State(tmp_path / "state", tmp_path / "checkout")
    backend = FakeHypervisor()
    backend.fail_prepare = True
    with pytest.raises(RuntimeError, match="first boot failed"):
        launch(state, backend)
    assert not (state.base(IMAGE).directory / "ready.json").exists()
    backend.fail_prepare = False
    launch(state, backend)
    assert backend.preparations == 2


def test_partial_instance_requires_explicit_reset(tmp_path: Path) -> None:
    state = State(tmp_path / "state", tmp_path / "checkout")
    backend = FakeHypervisor()
    launch(state, backend)
    backend.delete(state.instance)
    shutil.rmtree(state.instance.directory)
    backend.fail_clone = True
    with pytest.raises(RuntimeError, match="clone interrupted"):
        launch(state, backend)
    with pytest.raises(RuntimeError, match="incomplete"):
        launch(state, backend)
    backend.fail_clone = False
    launch(state, backend, reset=True)
    assert backend.preparations == 1


def test_missing_disk_is_reported_without_replacing_it(tmp_path: Path) -> None:
    state = State(tmp_path / "state", tmp_path / "checkout")
    backend = FakeHypervisor()
    launch(state, backend)
    backend.delete(state.instance)
    with pytest.raises(RuntimeError, match="disk is missing"):
        launch(state, backend)
    launch(state, backend, reset=True)


def test_instance_lock_rejects_second_launch_and_is_released(tmp_path: Path) -> None:
    state = State(tmp_path / "state", tmp_path / "checkout")
    backend = FakeHypervisor()
    with (
        lock(state.root / "locks" / f"{state.instance.name}.lock"),
        pytest.raises(RuntimeError, match="another VM operation"),
    ):
        launch(state, backend)
    assert backend.preparations == 0
    launch(state, backend)


def test_corrupt_nix_base_metadata_is_not_trusted(tmp_path: Path) -> None:
    state = State(tmp_path / "state", tmp_path / "checkout")
    backend = FakeHypervisor()
    launch(state, backend)
    (state.nix_base(IMAGE, BOOTSTRAP).directory / "ready.json").write_text(
        NixBase(image="wrong", bootstrap="wrong").model_dump_json()
    )
    with pytest.raises(RuntimeError, match="does not match"):
        launch(state, backend, reset=True)


def test_corrupt_macos_base_metadata_is_not_trusted(tmp_path: Path) -> None:
    state = State(tmp_path / "state", tmp_path / "checkout")
    backend = FakeHypervisor()
    base = ensure_base(state, backend, IMAGE)
    (base.directory / "ready.json").write_text(
        IMAGE.model_copy(update={"sha256": "b" * 64}).model_dump_json()
    )
    with pytest.raises(RuntimeError, match="does not match"):
        launch(state, backend)


def test_incomplete_nix_clone_is_recovered(tmp_path: Path) -> None:
    state = State(tmp_path / "state", tmp_path / "checkout")
    backend = FakeHypervisor()
    backend.fail_clone = True
    with pytest.raises(RuntimeError, match="clone interrupted"):
        launch(state, backend)
    backend.fail_clone = False
    launch(state, backend)
    assert backend.preparations == 1
    assert backend.nix_preparations == 1


def test_nix_base_lock_rejects_concurrent_preparation(tmp_path: Path) -> None:
    state = State(tmp_path / "state", tmp_path / "checkout")
    backend = FakeHypervisor()
    base = state.nix_base(IMAGE, BOOTSTRAP)
    with (
        lock(state.root / "locks" / f"{base.name}.lock"),
        pytest.raises(RuntimeError, match="another VM operation"),
    ):
        launch(state, backend)
    launch(state, backend)
