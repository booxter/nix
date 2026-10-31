from __future__ import annotations

import fcntl
import hashlib
import os
import shutil
from collections.abc import Iterator
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol

from atomic_file_writes import write_text_atomic
from pydantic import BaseModel, ConfigDict, Field


class Image(BaseModel):
    model_config = ConfigDict(frozen=True, extra="forbid")

    version: str
    build: str
    url: str
    sha256: str = Field(pattern=r"^[0-9a-f]{64}$")
    recipe: int = Field(ge=1)

    @property
    def key(self) -> str:
        return f"{self.sha256}-r{self.recipe}"


class Bootstrap(BaseModel):
    model_config = ConfigDict(frozen=True, extra="forbid")

    installer: Path
    version: str
    recipe: int = Field(ge=1)

    @property
    def key(self) -> str:
        return hashlib.sha256(self.model_dump_json().encode()).hexdigest()


class NixBase(BaseModel):
    model_config = ConfigDict(frozen=True, extra="forbid")

    image: str
    bootstrap: str


class Instance(BaseModel):
    model_config = ConfigDict(frozen=True, extra="forbid")

    base: str
    # Existing macOS-only disks must still reach SSH without waiting for Nix.
    nix: bool = False


@dataclass(frozen=True)
class Guest:
    name: str
    directory: Path

    @property
    def credentials(self) -> Path:
        return self.directory / "credentials"

    @property
    def ssh_config(self) -> Path:
        return self.directory / "ssh_config"


@dataclass(frozen=True)
class State:
    root: Path
    checkout: Path

    @property
    def instance(self) -> Guest:
        identity = hashlib.sha256(os.fsencode(self.checkout.resolve())).hexdigest()[:24]
        return Guest(f"worktree-{identity}", self.root / "instances" / identity)

    def base(self, image: Image) -> Guest:
        return Guest(f"base-{image.key}", self.root / "bases" / image.key)

    def nix_base(self, image: Image, bootstrap: Bootstrap) -> Guest:
        identity = hashlib.sha256(f"{image.key}:{bootstrap.key}".encode()).hexdigest()
        return Guest(f"nix-{identity}", self.root / "nix-bases" / identity)


class Hypervisor(Protocol):
    def exists(self, guest: Guest) -> bool: ...

    def delete(self, guest: Guest) -> None: ...

    def prepare_base(self, guest: Guest, image: Image) -> None: ...

    def prepare_nix(self, guest: Guest, bootstrap: Bootstrap) -> None: ...

    def clone(self, base: Guest, guest: Guest) -> None: ...

    def run(self, guest: Guest, *, gui: bool, nix: bool) -> int: ...


@contextmanager
def lock(path: Path) -> Iterator[None]:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    # Keep the inode in place so all contenders lock the same file.
    with path.open("a") as handle:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise RuntimeError(f"another VM operation holds {path}") from error
        try:
            yield
        finally:
            fcntl.flock(handle, fcntl.LOCK_UN)


def ensure_base(state: State, backend: Hypervisor, image: Image) -> Guest:
    base = state.base(image)
    ready = base.directory / "ready.json"
    if ready.exists() and backend.exists(base):
        if Image.model_validate_json(ready.read_text()).key != image.key:
            raise RuntimeError(f"base metadata does not match its image: {ready}")
        return base

    # A base contains no user work. Rebuild an interrupted preparation, but
    # publish readiness only after authenticated SSH and a clean shutdown.
    if backend.exists(base):
        backend.delete(base)
    if base.directory.exists():
        shutil.rmtree(base.directory)
    base.credentials.mkdir(parents=True, mode=0o700)
    backend.prepare_base(base, image)
    write_text_atomic(ready, image.model_dump_json())
    return base


def clone_guest(backend: Hypervisor, base: Guest, guest: Guest) -> None:
    guest.directory.mkdir(parents=True, mode=0o700)
    shutil.copytree(base.credentials, guest.credentials)
    backend.clone(base, guest)


def ensure_nix_base(state: State, backend: Hypervisor, image: Image, bootstrap: Bootstrap) -> Guest:
    base = state.nix_base(image, bootstrap)
    ready = base.directory / "ready.json"
    identity = NixBase(image=image.key, bootstrap=bootstrap.key)
    if ready.exists() and backend.exists(base):
        if NixBase.model_validate_json(ready.read_text()) != identity:
            raise RuntimeError(f"Nix base metadata does not match its inputs: {ready}")
        return base

    if backend.exists(base):
        backend.delete(base)
    if base.directory.exists():
        shutil.rmtree(base.directory)
    with lock(state.root / "locks" / f"base-{image.key}.lock"):
        macos_base = ensure_base(state, backend, image)
        clone_guest(backend, macos_base, base)
    backend.prepare_nix(base, bootstrap)
    write_text_atomic(ready, identity.model_dump_json())
    return base


def run_vm(
    state: State, backend: Hypervisor, image: Image, bootstrap: Bootstrap, *, gui: bool, reset: bool
) -> int:
    guest = state.instance
    with lock(state.root / "locks" / f"{guest.name}.lock"):
        if reset:
            if backend.exists(guest):
                backend.delete(guest)
            if guest.directory.exists():
                shutil.rmtree(guest.directory)

        ready = guest.directory / "ready.json"
        if ready.exists():
            instance = Instance.model_validate_json(ready.read_text())
            if not backend.exists(guest):
                raise RuntimeError("working VM disk is missing; use --reset macos to recreate it")
        else:
            if backend.exists(guest) or guest.directory.exists():
                raise RuntimeError("working VM preparation is incomplete; use --reset macos")
            nix_base = state.nix_base(image, bootstrap)
            with lock(state.root / "locks" / f"{nix_base.name}.lock"):
                base = ensure_nix_base(state, backend, image, bootstrap)
                clone_guest(backend, base, guest)
                instance = Instance(base=base.name, nix=True)
                write_text_atomic(ready, instance.model_dump_json())

        # Base updates affect new/reset VMs, never an existing disk.
        return backend.run(guest, gui=gui, nix=instance.nix)
