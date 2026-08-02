from __future__ import annotations

import json
import os
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol

import yaml

from .errors import ToolError
from .model import (
    JsonValue,
    KeyPath,
    deep_merge,
    has_path,
    require_json_value,
    scalar_leaves,
    value_at,
)
from .process import ProcessRunner
from .repository import SecretRepository


def load_yaml(path: Path) -> JsonValue:
    try:
        value: object = yaml.safe_load(path.read_text())
    except (OSError, yaml.YAMLError) as error:
        raise ToolError(f"Unable to read YAML from {path}: {error}") from error
    return require_json_value(value, source=str(path))


def write_atomic(path: Path, content: str) -> None:
    temporary_name: str | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            dir=path.parent,
            prefix=f".{path.name}.",
            delete=False,
        ) as temporary:
            temporary.write(content)
            temporary_name = temporary.name
        os.replace(temporary_name, path)
    finally:
        if temporary_name is not None:
            Path(temporary_name).unlink(missing_ok=True)


class SopsBackend(Protocol):
    def decrypt_text(self, path: Path) -> str: ...

    def decrypt_data(self, path: Path) -> JsonValue: ...

    def edit(self, path: Path) -> None: ...

    def set_value(self, path: Path, key_path: KeyPath, value: JsonValue) -> None: ...

    def encrypt_data(self, path: Path, value: JsonValue) -> str: ...

    def encrypt_yaml(self, path: Path, plaintext: str) -> str: ...


@dataclass(frozen=True)
class CommandSopsBackend:
    runner: ProcessRunner

    def decrypt_text(self, path: Path) -> str:
        return self.runner.run(["sops", "--decrypt", str(path)])

    def decrypt_data(self, path: Path) -> JsonValue:
        plaintext = self.decrypt_text(path)
        try:
            value: object = yaml.safe_load(plaintext)
        except yaml.YAMLError as error:
            raise ToolError(
                f"SOPS returned invalid YAML for {path}: {error}"
            ) from error
        return require_json_value(value, source=str(path))

    def edit(self, path: Path) -> None:
        self.runner.run(["sops", str(path)], capture_output=False)

    def set_value(self, path: Path, key_path: KeyPath, value: JsonValue) -> None:
        self.runner.run(
            [
                "sops",
                "set",
                "--idempotent",
                "--value-stdin",
                str(path),
                key_path.sops_index(),
            ],
            input_text=json.dumps(value, separators=(",", ":")),
        )

    def encrypt_data(self, path: Path, value: JsonValue) -> str:
        return self.runner.run(
            [
                "sops",
                "--encrypt",
                "--filename-override",
                str(path),
                "--input-type",
                "json",
                "--output-type",
                "yaml",
                "/dev/stdin",
            ],
            input_text=json.dumps(value, separators=(",", ":")),
        )

    def encrypt_yaml(self, path: Path, plaintext: str) -> str:
        return self.runner.run(
            [
                "sops",
                "--encrypt",
                "--filename-override",
                str(path),
                "--input-type",
                "yaml",
                "--output-type",
                "yaml",
                "/dev/stdin",
            ],
            input_text=plaintext,
        )


@dataclass(frozen=True)
class UpdateResult:
    secret: Path
    changed: bool
    reencrypted: bool


@dataclass
class SecretService:
    repository: SecretRepository
    sops: SopsBackend

    def cat(self, host: str) -> str:
        return self.sops.decrypt_text(self.repository.require_secret(host))

    def edit(self, host: str) -> Path:
        secret = self.repository.require_secret(host)
        self.sops.edit(secret)
        return secret

    def set_text(self, host: str, key_path: KeyPath, value: str) -> Path:
        secret = self.repository.require_secret(host)
        self.sops.set_value(secret, key_path, value)
        return secret

    def copy(
        self,
        source_host: str,
        destination_host: str,
        source_path: KeyPath,
        destination_path: KeyPath,
    ) -> Path:
        source = self.repository.require_secret(source_host, role="Source")
        destination = self.repository.require_secret(
            destination_host, role="Destination"
        )
        source_document = self.sops.decrypt_data(source)
        try:
            value = value_at(source_document, source_path)
        except ToolError as error:
            raise ToolError(
                f"Path not found in source secret: {source_path.display()}"
            ) from error
        self.sops.set_value(destination, destination_path, value)
        return destination

    def update(self, host: str, *, force: bool = False) -> UpdateResult:
        template = self.repository.template
        if not template.is_file():
            raise ToolError(f"Template not found: {template}")
        secret = self.repository.require_secret(host)

        desired = load_yaml(template)
        host_template = self.repository.host_template(host)
        if host_template.is_file():
            desired = deep_merge(desired, load_yaml(host_template))

        current = self.sops.decrypt_data(secret)
        desired = deep_merge(desired, current)
        if not force and current == desired:
            return UpdateResult(secret, changed=False, reencrypted=False)

        if force:
            write_atomic(secret, self.sops.encrypt_data(secret, desired))
            return UpdateResult(secret, changed=True, reencrypted=True)

        missing = [
            (path, value)
            for path, value in scalar_leaves(desired)
            if not has_path(current, path)
        ]
        if missing:
            for path, value in missing:
                self.sops.set_value(secret, path, value)
            return UpdateResult(secret, changed=True, reencrypted=False)

        write_atomic(secret, self.sops.encrypt_data(secret, desired))
        return UpdateResult(secret, changed=True, reencrypted=True)
