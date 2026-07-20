import importlib.util
import os
import pathlib
import sys

import pytest


MODULE_PATH = pathlib.Path(os.environ["OPEN_WEBUI_TOOL_ACL_RECONCILE_MAIN"])
SPEC = importlib.util.spec_from_file_location(
    "open_webui_tool_acl_reconcile", MODULE_PATH
)
reconcile = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = reconcile
SPEC.loader.exec_module(reconcile)


def connection(server_id, grants=None):
    return {
        "type": "mcp",
        "info": {"id": server_id, "name": server_id},
        "config": {
            "enable": True,
            "access_grants": grants
            if grants is not None
            else [
                {
                    "principal_type": "user",
                    "principal_id": "*",
                    "permission": "read",
                }
            ],
        },
    }


def test_with_group_read_grant_replaces_only_target_acl():
    connections = [connection("other"), connection("paperless")]

    updated = reconcile.with_group_read_grant(
        connections,
        "paperless",
        "group-id",
    )

    assert updated[0] == connections[0]
    assert updated[1]["config"]["access_grants"] == [
        {
            "principal_type": "group",
            "principal_id": "group-id",
            "permission": "read",
        }
    ]
    assert connections[1]["config"]["access_grants"][0]["principal_id"] == "*"


@pytest.mark.parametrize(
    "connections",
    [
        [],
        [connection("paperless"), connection("paperless")],
        {"paperless": connection("paperless")},
    ],
)
def test_with_group_read_grant_requires_one_target(connections):
    with pytest.raises(RuntimeError):
        reconcile.with_group_read_grant(connections, "paperless", "group-id")


def test_verify_group_read_grant_rejects_additional_grants():
    grants = [
        {
            "principal_type": "group",
            "principal_id": "group-id",
            "permission": "read",
        },
        {
            "principal_type": "user",
            "principal_id": "*",
            "permission": "read",
        },
    ]

    with pytest.raises(RuntimeError):
        reconcile.verify_group_read_grant(
            [connection("paperless", grants)],
            "paperless",
            "group-id",
        )


class FakeClient(reconcile.OpenWebUIClient):
    def __init__(self, settings, responses):
        super().__init__(settings)
        self.responses = list(responses)
        self.calls = []
        self.token = "test-token"

    def api(self, method, path, payload=None, authenticated=True):
        self.calls.append((method, path, payload, authenticated))
        return self.responses.pop(0)


def settings():
    return reconcile.Settings(
        base_url="http://open-webui.test",
        admin_email="admin@example.test",
        admin_password="secret",
        group_name="paperless-users",
        tool_server_id="paperless",
    )


def test_ensure_group_reuses_existing_group():
    client = FakeClient(settings(), [[{"id": "group-id", "name": "paperless-users"}]])

    assert client.ensure_group() == "group-id"
    assert client.calls == [("GET", "/api/v1/groups/", None, True)]


def test_ensure_group_creates_private_group():
    created = {"id": "group-id", "name": "paperless-users"}
    client = FakeClient(settings(), [[], created])

    assert client.ensure_group() == "group-id"
    assert client.calls[1] == (
        "POST",
        "/api/v1/groups/create",
        {
            "name": "paperless-users",
            "description": "Access synchronized from the SSO Paperless group.",
            "data": {"config": {"share": False}},
        },
        True,
    )


def test_ensure_group_rejects_duplicate_names():
    client = FakeClient(
        settings(),
        [
            [
                {"id": "group-one", "name": "paperless-users"},
                {"id": "group-two", "name": "paperless-users"},
            ]
        ],
    )

    with pytest.raises(RuntimeError):
        client.ensure_group()
