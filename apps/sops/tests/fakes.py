from __future__ import annotations

import copy
from dataclasses import dataclass, field
from pathlib import Path
from typing import Sequence

import yaml

from sops_tools.model import JsonValue, KeyPath
from sops_tools.secrets import SopsBackend


@dataclass
class RecordingRunner:
    outputs: list[str] = field(default_factory=list)
    calls: list[tuple[list[str], str | None, bool]] = field(default_factory=list)

    def run(
        self,
        argv: Sequence[str],
        *,
        input_text: str | None = None,
        capture_output: bool = True,
    ) -> str:
        self.calls.append((list(argv), input_text, capture_output))
        return self.outputs.pop(0) if self.outputs else ""


@dataclass
class MemorySopsBackend:
    documents: dict[Path, JsonValue]
    set_calls: list[tuple[Path, KeyPath, JsonValue]] = field(default_factory=list)
    edits: list[Path] = field(default_factory=list)
    encryptions: list[tuple[Path, JsonValue]] = field(default_factory=list)

    def decrypt_text(self, path: Path) -> str:
        return yaml.safe_dump(self.documents[path], sort_keys=False)

    def decrypt_data(self, path: Path) -> JsonValue:
        return copy.deepcopy(self.documents[path])

    def edit(self, path: Path) -> None:
        self.edits.append(path)

    def set_value(self, path: Path, key_path: KeyPath, value: JsonValue) -> None:
        self.set_calls.append((path, key_path, copy.deepcopy(value)))
        current: JsonValue = self.documents[path]
        for index, segment in enumerate(key_path.segments[:-1]):
            next_segment = key_path.segments[index + 1]
            if isinstance(segment, int):
                assert isinstance(current, list)
                current = current[segment]
            else:
                assert isinstance(current, dict)
                child = current.setdefault(
                    segment, [] if isinstance(next_segment, int) else {}
                )
                current = child
        final = key_path.segments[-1]
        if isinstance(final, int):
            assert isinstance(current, list)
            if final == len(current):
                current.append(copy.deepcopy(value))
            else:
                current[final] = copy.deepcopy(value)
        else:
            assert isinstance(current, dict)
            current[final] = copy.deepcopy(value)

    def encrypt_data(self, path: Path, value: JsonValue) -> str:
        self.encryptions.append((path, copy.deepcopy(value)))
        self.documents[path] = copy.deepcopy(value)
        return "encrypted\n"

    def encrypt_yaml(self, path: Path, plaintext: str) -> str:
        value = yaml.safe_load(plaintext)
        self.documents[path] = value
        return "encrypted\n"


@dataclass(frozen=True)
class StaticBackendFactory:
    backend: SopsBackend

    def create(self, environment: object) -> SopsBackend:
        return self.backend
