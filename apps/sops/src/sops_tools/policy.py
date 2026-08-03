from __future__ import annotations

import os
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import cast

import yaml

from .errors import ToolError
from .model import JsonValue, require_json_value


def _string_list(value: JsonValue, *, description: str, allow_empty: bool) -> list[str]:
    if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
        raise ToolError(
            f".sops.yaml must contain a top-level '{description}' sequence."
        )
    if not value and not allow_empty:
        raise ToolError(f".sops.yaml '{description}' sequence must not be empty.")
    return cast(list[str], value)


@dataclass
class SopsPolicy:
    document: dict[str, JsonValue]

    @classmethod
    def load(cls, path: Path) -> SopsPolicy:
        try:
            value: object = yaml.safe_load(path.read_text())
        except (OSError, yaml.YAMLError) as error:
            raise ToolError(f"Unable to read {path}: {error}") from error
        document = require_json_value(value, source=str(path))
        if not isinstance(document, dict):
            raise ToolError(".sops.yaml must be a YAML map at top-level.")
        policy = cls(document)
        policy.validate()
        return policy

    @classmethod
    def create(cls) -> SopsPolicy:
        return cls({"keys": [], "creation_rules": []})

    def validate(self, *, allow_empty: bool = False) -> None:
        keys = self.document.get("keys")
        if (
            keys is None
            or not isinstance(keys, list)
            or not all(isinstance(item, str) for item in keys)
        ):
            raise ToolError(".sops.yaml must contain a top-level 'keys' sequence.")
        if not keys and not allow_empty:
            raise ToolError(".sops.yaml 'keys' sequence must not be empty.")

        rules = self.document.get("creation_rules")
        if not isinstance(rules, list):
            raise ToolError(
                ".sops.yaml must contain a top-level 'creation_rules' sequence."
            )
        if not rules and not allow_empty:
            raise ToolError(".sops.yaml 'creation_rules' sequence must not be empty.")

    @property
    def keys(self) -> list[str]:
        return _string_list(self.document["keys"], description="keys", allow_empty=True)

    @property
    def creation_rules(self) -> list[dict[str, JsonValue]]:
        value = self.document["creation_rules"]
        if not isinstance(value, list) or not all(
            isinstance(rule, dict) for rule in value
        ):
            raise ToolError(
                ".sops.yaml must contain a top-level 'creation_rules' sequence."
            )
        return cast(list[dict[str, JsonValue]], value)

    def recipients_for_rule(self, path_regex: str) -> list[str]:
        for rule in self.creation_rules:
            if rule.get("path_regex") != path_regex:
                continue
            groups = rule.get("key_groups", [])
            if not isinstance(groups, list):
                return []
            recipients: list[str] = []
            for group in groups:
                if not isinstance(group, dict):
                    continue
                age = group.get("age", [])
                if isinstance(age, list):
                    recipients.extend(item for item in age if isinstance(item, str))
            return recipients
        return []

    def domain_recipients(self, domain: str) -> set[str]:
        prefix = f"secrets/{domain}/"
        recipients: set[str] = set()
        for rule in self.creation_rules:
            path_regex = rule.get("path_regex")
            if isinstance(path_regex, str) and path_regex.startswith(prefix):
                recipients.update(self.recipients_for_rule(path_regex))
        return recipients

    def ensure_host_rule(self, domain: str, host: str, recipients: list[str]) -> bool:
        unique_recipients = list(dict.fromkeys(recipients))
        changed = False
        keys = self.keys
        for recipient in unique_recipients:
            if recipient not in keys:
                keys.append(recipient)
                changed = True

        path_regex = f"secrets/{domain}/{host}\\.yaml$"
        for rule in self.creation_rules:
            if rule.get("path_regex") != path_regex:
                continue
            groups = rule.get("key_groups")
            if (
                not isinstance(groups, list)
                or not groups
                or not isinstance(groups[0], dict)
            ):
                raise ToolError(f"Invalid age key group for policy rule: {path_regex}")
            age = groups[0].get("age")
            if not isinstance(age, list) or not all(
                isinstance(item, str) for item in age
            ):
                raise ToolError(f"Invalid age key group for policy rule: {path_regex}")
            for recipient in unique_recipients:
                if recipient not in age:
                    age.append(recipient)
                    changed = True
            return changed

        age_values: list[JsonValue] = list(unique_recipients)
        self.creation_rules.append(
            {
                "path_regex": path_regex,
                "key_groups": [{"age": age_values}],
            }
        )
        return True

    def write(self, path: Path) -> None:
        content = yaml.safe_dump(self.document, sort_keys=False)
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


def validate_repository(root: Path) -> None:
    secret_files = [
        path
        for path in (root / "secrets").glob("*/*.yaml")
        if path.name != "_template.yaml"
    ]
    policy_path = root / ".sops.yaml"
    if secret_files and not policy_path.is_file():
        raise ToolError("secrets/*/*.yaml present but .sops.yaml is missing.")
    if not policy_path.is_file():
        return

    policy = SopsPolicy.load(policy_path)
    for secret in secret_files:
        value = load_encrypted_yaml(secret)
        if not isinstance(value, dict) or not isinstance(value.get("sops"), dict):
            relative = secret.relative_to(root)
            raise ToolError(f"{relative} is missing a 'sops' block (not encrypted?).")

    overlap = policy.domain_recipients("main") & policy.domain_recipients("work")
    if overlap:
        recipients = "\n".join(sorted(overlap))
        raise ToolError(
            f"Secret domains main and work share age recipients:\n{recipients}"
        )


def load_encrypted_yaml(path: Path) -> JsonValue:
    try:
        value: object = yaml.safe_load(path.read_text())
    except (OSError, yaml.YAMLError) as error:
        raise ToolError(f"Unable to read YAML from {path}: {error}") from error
    return require_json_value(value, source=str(path))
