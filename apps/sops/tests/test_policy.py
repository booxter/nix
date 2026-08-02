from __future__ import annotations

from pathlib import Path

import pytest
import yaml

from sops_tools.errors import ToolError
from sops_tools.policy import SopsPolicy, validate_repository


@pytest.mark.parametrize(
    ("document", "message"),
    [
        (["not-a-map"], "YAML map"),
        ({"keys": {}, "creation_rules": []}, "'keys' sequence"),
        ({"keys": [], "creation_rules": [{}]}, "must not be empty"),
        ({"keys": ["age1test"], "creation_rules": {}}, "'creation_rules' sequence"),
        ({"keys": ["age1test"], "creation_rules": []}, "must not be empty"),
    ],
)
def test_policy_rejects_invalid_top_level_contracts(
    tmp_path: Path, document: object, message: str
) -> None:
    path = tmp_path / ".sops.yaml"
    path.write_text(yaml.safe_dump(document))

    with pytest.raises(ToolError, match=message):
        SopsPolicy.load(path)


def test_ensure_host_rule_adds_unique_recipients_and_is_idempotent() -> None:
    policy = SopsPolicy.create()

    assert policy.ensure_host_rule("main", "beast", ["age1host", "age1operator"])
    assert not policy.ensure_host_rule("main", "beast", ["age1host", "age1operator"])
    assert policy.keys == ["age1host", "age1operator"]
    assert policy.recipients_for_rule("secrets/main/beast\\.yaml$") == [
        "age1host",
        "age1operator",
    ]


def test_repository_policy_and_secrets_are_valid() -> None:
    validate_repository(Path(__file__).parents[3])
