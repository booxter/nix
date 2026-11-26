import argparse
import base64
import hashlib
import os
import pathlib
import subprocess
import sys
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from typing import Protocol

from pydantic import BaseModel, TypeAdapter


class Identity(BaseModel):
    serial: str
    public_key: str
    pin_first: bool = False

    @property
    def fingerprint(self) -> str:
        encoded = self.public_key.split()[1]
        digest = hashlib.sha256(base64.b64decode(encoded, validate=True)).digest()
        return "SHA256:" + base64.b64encode(digest).decode().rstrip("=")


@dataclass(frozen=True)
class Device:
    serial: str
    path: str


class Discovery(Protocol):
    def devices(self) -> Sequence[Device]: ...


class Agent(Protocol):
    def fingerprints(self) -> set[str]: ...

    def add(self, path: pathlib.Path) -> None: ...

    def remove(self, path: pathlib.Path) -> None: ...


@dataclass
class OpenSSHAgent:
    environment: Mapping[str, str] | None = None

    def fingerprints(self) -> set[str]:
        result = subprocess.run(
            ["ssh-add", "-L"], capture_output=True, text=True, env=self.environment, check=False
        )
        if result.returncode == 1:
            return set()
        result.check_returncode()
        return {
            Identity(serial="", public_key=line).fingerprint for line in result.stdout.splitlines()
        }

    def add(self, path: pathlib.Path) -> None:
        subprocess.run(["ssh-add", "-q", str(path)], check=True, env=self.environment)

    def remove(self, path: pathlib.Path) -> None:
        subprocess.run(
            ["ssh-add", "-q", "-d", str(path) + ".pub"], check=True, env=self.environment
        )


def libfido_path(path: str, platform: str) -> str:
    # python-fido2 and libfido2 use the same IOKit registry ID,
    # but nixpkgs builds libfido2 with HIDAPI, which prefixes it with DevSrvsID:.
    if platform == "darwin":
        return "DevSrvsID:" + path

    return path


class YubikeyDiscovery:
    def devices(self) -> Sequence[Device]:
        from ykman.device import list_all_devices
        from yubikit.core.fido import FidoConnection

        devices = []
        for device, info in list_all_devices([FidoConnection]):
            if info.serial is None:
                continue

            path = libfido_path(str(device.fingerprint), sys.platform)
            devices.append(Device(str(info.serial), path))

        return devices


def device_path(identities: Sequence[Identity], fingerprint: str, discovery: Discovery) -> str:
    identity = next((key for key in identities if key.fingerprint == fingerprint), None)
    if identity is None:
        # Unknown identities retain OpenSSH's normal discovery behavior.
        return ""

    matches = [device for device in discovery.devices() if device.serial == identity.serial]
    if len(matches) != 1:
        raise ValueError(f"Expected one connected YubiKey with serial {identity.serial}")

    return matches[0].path


def preferred_identity(
    identities: Sequence[Identity], serials: Sequence[str], discovery: Discovery
) -> Identity:
    present = {device.serial for device in discovery.devices()}
    for serial in serials:
        if serial in present:
            for identity in identities:
                if identity.serial == serial:
                    return identity

    raise ValueError("No preferred YubiKey is connected")


def load_identity(
    identities: Sequence[Identity],
    paths: Sequence[pathlib.Path],
    discovery: Discovery,
    agent: Agent,
) -> Identity:
    by_fingerprint = {key.fingerprint: key for key in identities}
    handles = []
    for path in paths:
        public_key = pathlib.Path(str(path) + ".pub").read_text()
        fingerprint = Identity(serial="", public_key=public_key).fingerprint
        if fingerprint not in by_fingerprint:
            raise ValueError(f"No YubiKey inventory entry for {path}")
        handles.append((path, by_fingerprint[fingerprint]))

    selected = preferred_identity(identities, [key.serial for _, key in handles], discovery)
    loaded = agent.fingerprints()
    selected_path = next(path for path, key in handles if key == selected)
    if selected.fingerprint not in loaded:
        agent.add(selected_path)

    # Remove only the other configured handles. Unrelated agent keys survive,
    # and an unavailable token cannot remain first for forwarded authentication.
    for path, key in handles:
        if key != selected and key.fingerprint in loaded:
            agent.remove(path)
    return selected


def run(argv: Sequence[str], discovery: Discovery, agent: Agent | None = None) -> int:
    parser = argparse.ArgumentParser(description="Select an SSH YubiKey without a touch")
    parser.add_argument(
        "--identities",
        type=pathlib.Path,
        default=pathlib.Path("/etc/ssh/ssh-device-identities.json"),
    )
    commands = parser.add_subparsers(dest="command", required=True)
    device = commands.add_parser("device")
    device.add_argument("fingerprint")
    pin_first = commands.add_parser(
        "pin-first", help="Test whether to prompt for a PIN before touch"
    )
    pin_first.add_argument("fingerprint")
    preferred = commands.add_parser("preferred")
    preferred.add_argument("serials", nargs="+")
    load = commands.add_parser("load")
    load.add_argument("paths", nargs="+", type=pathlib.Path)
    args = parser.parse_args(argv)

    try:
        identities = TypeAdapter(list[Identity]).validate_json(args.identities.read_text())
        if args.command == "pin-first":
            return (
                0
                if any(key.fingerprint == args.fingerprint and key.pin_first for key in identities)
                else 1
            )
        if args.command == "device":
            path = device_path(identities, args.fingerprint, discovery)
            if path:
                print(path)
        elif args.command == "preferred":
            print(preferred_identity(identities, args.serials, discovery).public_key.strip())
        else:
            if os.environ.get("SSH_CONNECTION"):
                raise ValueError("Refusing to change a forwarded agent")
            selected = load_identity(identities, args.paths, discovery, agent or OpenSSHAgent())
            print(selected.public_key.strip())
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"ssh-device: {error}", file=sys.stderr)
        return 1

    return 0


def main() -> int:
    return run(sys.argv[1:], YubikeyDiscovery())
