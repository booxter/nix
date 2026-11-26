import json
from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path

import pytest
from ssh_device import Device, Identity, device_path, libfido_path, preferred_identity, run

DOCK = Identity(serial="100", public_key="ssh-ed25519 ZG9jaw== dock")
LAPTOP = Identity(serial="200", public_key="ssh-ed25519 bGFwdG9w laptop")


def test_device_paths_match_libfido2_format() -> None:
    assert libfido_path("4295545266", "darwin") == "DevSrvsID:4295545266"
    assert libfido_path("/dev/hidraw3", "linux") == "/dev/hidraw3"


@dataclass
class Connected:
    connected: Sequence[Device]

    def devices(self) -> Sequence[Device]:
        return self.connected


def test_preference_does_not_depend_on_enumeration_order() -> None:
    discovery = Connected([Device("200", "laptop"), Device("100", "dock")])
    assert preferred_identity([LAPTOP, DOCK], ["100", "200"], discovery) == DOCK


def test_undocked_falls_back_to_laptop() -> None:
    assert (
        preferred_identity([DOCK, LAPTOP], ["100", "200"], Connected([Device("200", "laptop")]))
        == LAPTOP
    )


def test_requested_key_wins_over_preference() -> None:
    discovery = Connected([Device("100", "dock"), Device("200", "laptop")])
    assert device_path([DOCK, LAPTOP], LAPTOP.fingerprint, discovery) == "laptop"


def test_reconnection_resolves_new_path() -> None:
    discovery = Connected([Device("100", "old")])
    assert device_path([DOCK], DOCK.fingerprint, discovery) == "old"
    discovery.connected = [Device("100", "new")]
    assert device_path([DOCK], DOCK.fingerprint, discovery) == "new"


@pytest.mark.parametrize("devices", [[], [Device("100", "a"), Device("100", "b")]])
def test_missing_or_ambiguous_device_does_not_choose_another(devices: list[Device]) -> None:
    with pytest.raises(ValueError, match="Expected one connected"):
        device_path([DOCK], DOCK.fingerprint, Connected(devices))


def test_unknown_identity_preserves_default_discovery() -> None:
    assert device_path([DOCK], LAPTOP.fingerprint, Connected([])) == ""


def test_no_preferred_device() -> None:
    with pytest.raises(ValueError, match="No preferred"):
        preferred_identity([DOCK], ["100"], Connected([Device("300", "home")]))


def test_pin_prompt_follows_current_manifest_without_connected_devices(tmp_path: Path) -> None:
    manifest = tmp_path / "identities.json"
    command = ["--identities", str(manifest), "pin-first"]
    disconnected = Connected([])

    def set_policy(pin_first: bool) -> None:
        identity = DOCK.model_copy(update={"pin_first": pin_first})
        manifest.write_text(json.dumps([identity.model_dump(), LAPTOP.model_dump()]))

    set_policy(True)
    assert run([*command, DOCK.fingerprint], disconnected) == 0
    assert run([*command, LAPTOP.fingerprint], disconnected) == 1
    assert run([*command, "unknown"], disconnected) == 1

    set_policy(False)
    assert run([*command, DOCK.fingerprint], disconnected) == 1


def test_cli(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    manifest = tmp_path / "identities.json"
    manifest.write_text(json.dumps([DOCK.model_dump(), LAPTOP.model_dump()]))
    prefix = ["--identities", str(manifest)]
    discovery = Connected([Device("100", "dock")])
    assert run([*prefix, "device", DOCK.fingerprint], discovery) == 0
    assert capsys.readouterr().out == "dock\n"
    assert run([*prefix, "device", "unknown"], discovery) == 0
    assert capsys.readouterr().out == ""
    assert run([*prefix, "preferred", "100", "200"], discovery) == 0
    assert capsys.readouterr().out == DOCK.public_key + "\n"
    assert run([*prefix, "device", LAPTOP.fingerprint], discovery) == 1
    assert "Expected one connected" in capsys.readouterr().err
    manifest.write_text("invalid")
    assert run([*prefix, "preferred", "100"], discovery) == 1
