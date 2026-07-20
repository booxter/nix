import json
import os
import time
import urllib.error
import urllib.request
from dataclasses import dataclass


@dataclass(frozen=True)
class Settings:
    base_url: str
    admin_email: str
    admin_password: str
    group_name: str
    tool_server_id: str
    wait_seconds: int = 120

    @classmethod
    def from_environment(cls):
        return cls(
            base_url=os.environ["OPEN_WEBUI_BASE_URL"].rstrip("/"),
            admin_email=os.environ["OPEN_WEBUI_ADMIN_EMAIL"],
            admin_password=os.environ["WEBUI_ADMIN_PASSWORD"],
            group_name=os.environ["OPEN_WEBUI_ACCESS_GROUP"],
            tool_server_id=os.environ["OPEN_WEBUI_TOOL_SERVER_ID"],
            wait_seconds=int(os.environ.get("OPEN_WEBUI_WAIT_SECONDS", "120")),
        )


class OpenWebUIClient:
    def __init__(self, settings):
        self.settings = settings
        self.token = None

    def api(self, method, path, payload=None, authenticated=True):
        headers = {
            "Accept": "application/json",
            "Content-Type": "application/json",
        }
        if authenticated:
            if not self.token:
                raise RuntimeError("Open WebUI API authentication is required")
            headers["Authorization"] = f"Bearer {self.token}"

        request = urllib.request.Request(
            f"{self.settings.base_url}{path}",
            data=None if payload is None else json.dumps(payload).encode(),
            method=method,
            headers=headers,
        )
        try:
            with urllib.request.urlopen(request, timeout=10) as response:
                body = response.read()
        except urllib.error.HTTPError as error:
            body = error.read().decode(errors="replace")
            raise RuntimeError(
                f"{method} {path} failed with HTTP {error.code}: {body}"
            ) from error

        return None if not body else json.loads(body)

    def wait_until_ready(self):
        deadline = time.monotonic() + self.settings.wait_seconds
        last_error = None
        while time.monotonic() < deadline:
            try:
                self.api("GET", "/health", authenticated=False)
                return
            except (OSError, RuntimeError) as error:
                last_error = error
                time.sleep(2)
        raise RuntimeError(f"timed out waiting for Open WebUI: {last_error}")

    def sign_in(self):
        response = self.api(
            "POST",
            "/api/v1/auths/signin",
            {
                "email": self.settings.admin_email,
                "password": self.settings.admin_password,
            },
            authenticated=False,
        )
        token = response.get("token") if isinstance(response, dict) else None
        if not isinstance(token, str) or not token:
            raise RuntimeError("Open WebUI sign-in response did not contain a token")
        self.token = token

    def ensure_group(self):
        groups = self.api("GET", "/api/v1/groups/")
        if not isinstance(groups, list):
            raise RuntimeError("Open WebUI groups response was not a list")

        matches = [
            group for group in groups if group.get("name") == self.settings.group_name
        ]
        if len(matches) > 1:
            raise RuntimeError(
                f"multiple Open WebUI groups are named {self.settings.group_name!r}"
            )
        if matches:
            return require_id(matches[0], "Open WebUI group")

        group = self.api(
            "POST",
            "/api/v1/groups/create",
            {
                "name": self.settings.group_name,
                "description": "Access synchronized from the SSO Paperless group.",
                "data": {"config": {"share": False}},
            },
        )
        if not isinstance(group, dict) or group.get("name") != self.settings.group_name:
            raise RuntimeError("Open WebUI did not return the requested group")
        return require_id(group, "created Open WebUI group")

    def reconcile_tool_server(self, group_id):
        response = self.api("GET", "/api/v1/configs/tool_servers")
        connections = (
            response.get("TOOL_SERVER_CONNECTIONS")
            if isinstance(response, dict)
            else None
        )
        updated_connections = with_group_read_grant(
            connections,
            self.settings.tool_server_id,
            group_id,
        )
        updated = self.api(
            "POST",
            "/api/v1/configs/tool_servers",
            {"TOOL_SERVER_CONNECTIONS": updated_connections},
        )
        returned_connections = (
            updated.get("TOOL_SERVER_CONNECTIONS")
            if isinstance(updated, dict)
            else None
        )
        verify_group_read_grant(
            returned_connections,
            self.settings.tool_server_id,
            group_id,
        )


def require_id(item, description):
    item_id = item.get("id") if isinstance(item, dict) else None
    if not isinstance(item_id, str) or not item_id:
        raise RuntimeError(f"{description} did not contain an ID")
    return item_id


def matching_connections(connections, tool_server_id):
    if not isinstance(connections, list):
        raise RuntimeError("Open WebUI tool server connections response was not a list")
    return [
        connection
        for connection in connections
        if isinstance(connection, dict)
        and isinstance(connection.get("info"), dict)
        and connection["info"].get("id") == tool_server_id
    ]


def with_group_read_grant(connections, tool_server_id, group_id):
    matches = matching_connections(connections, tool_server_id)
    if len(matches) != 1:
        raise RuntimeError(
            f"expected one Open WebUI tool server named {tool_server_id!r}, found {len(matches)}"
        )

    desired_grants = [
        {
            "principal_type": "group",
            "principal_id": group_id,
            "permission": "read",
        }
    ]
    result = []
    for original_connection in connections:
        connection = dict(original_connection)
        if original_connection is matches[0]:
            config = original_connection.get("config")
            config = dict(config) if isinstance(config, dict) else {}
            config["access_grants"] = desired_grants
            connection["config"] = config
        result.append(connection)
    return result


def verify_group_read_grant(connections, tool_server_id, group_id):
    matches = matching_connections(connections, tool_server_id)
    if len(matches) != 1:
        raise RuntimeError(
            f"expected one reconciled Open WebUI tool server named {tool_server_id!r}, found {len(matches)}"
        )
    config = matches[0].get("config")
    grants = config.get("access_grants") if isinstance(config, dict) else None
    expected = [
        {
            "principal_type": "group",
            "principal_id": group_id,
            "permission": "read",
        }
    ]
    if grants != expected:
        raise RuntimeError("Open WebUI did not retain the requested tool server ACL")


def main():
    settings = Settings.from_environment()
    client = OpenWebUIClient(settings)
    client.wait_until_ready()
    client.sign_in()
    group_id = client.ensure_group()
    client.reconcile_tool_server(group_id)
    print(
        f"Restricted Open WebUI tool server {settings.tool_server_id!r} "
        f"to group {settings.group_name!r}."
    )


if __name__ == "__main__":
    main()
