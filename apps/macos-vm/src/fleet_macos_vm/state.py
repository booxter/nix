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


class Instance(BaseModel):
    model_config = ConfigDict(frozen=True, extra="forbid")

    base: str


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


class Hypervisor(Protocol):
    def exists(self, guest: Guest) -> bool: ...

    def delete(self, guest: Guest) -> None: ...

    def prepare_base(self, guest: Guest, image: Image) -> None: ...

    def clone(self, base: Guest, guest: Guest) -> None: ...

    def run(self, guest: Guest, *, gui: bool) -> int: ...


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


def run_vm(state: State, backend: Hypervisor, image: Image, *, gui: bool, reset: bool) -> int:
    guest = state.instance
    with lock(state.root / "locks" / f"{guest.name}.lock"):
        if reset:
            if backend.exists(guest):
                backend.delete(guest)
            if guest.directory.exists():
                shutil.rmtree(guest.directory)

        ready = guest.directory / "ready.json"
        if ready.exists():
            Instance.model_validate_json(ready.read_text())
            if not backend.exists(guest):
                raise RuntimeError("working VM disk is missing; use --reset macos to recreate it")
        else:
            if backend.exists(guest) or guest.directory.exists():
                raise RuntimeError("working VM preparation is incomplete; use --reset macos")
            with lock(state.root / "locks" / f"base-{image.key}.lock"):
                base = ensure_base(state, backend, image)
                guest.directory.mkdir(parents=True, mode=0o700)
                shutil.copytree(base.credentials, guest.credentials)
                backend.clone(base, guest)
                write_text_atomic(ready, Instance(base=image.key).model_dump_json())

        # An image pin change affects new/reset VMs, never an existing disk.
        return backend.run(guest, gui=gui)
