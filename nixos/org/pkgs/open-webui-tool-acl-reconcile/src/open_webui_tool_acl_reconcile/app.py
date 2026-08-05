import os
import sys
import time
import urllib.parse
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from typing import Literal, Protocol, Self, cast

import httpx
from pydantic import (
    BaseModel,
    ConfigDict,
    Field,
    SecretStr,
    TypeAdapter,
    ValidationError,
    field_validator,
)


class Error(RuntimeError):
    pass


class Settings(BaseModel):
    model_config = ConfigDict(frozen=True, strict=True)

    base_url: str = Field(min_length=1)
    admin_email: str = Field(min_length=1)
    admin_password: SecretStr
    group_name: str = Field(min_length=1)
    tool_server_id: str = Field(min_length=1)
    wait_seconds: float = Field(default=120, gt=0)
    poll_seconds: float = Field(default=2, gt=0)

    @field_validator("base_url")
    @classmethod
    def validate_base_url(cls, value: str) -> str:
        normalized = value.rstrip("/")
        parsed = urllib.parse.urlparse(normalized)
        if parsed.scheme not in {"http", "https"} or parsed.netloc == "":
            raise ValueError("base_url must be an HTTP(S) URL")
        return normalized

    @classmethod
    def from_environment(cls, environment: Mapping[str, str] | None = None) -> Self:
        values = os.environ if environment is None else environment
        try:
            return cls(
                base_url=values["OPEN_WEBUI_BASE_URL"],
                admin_email=values["OPEN_WEBUI_ADMIN_EMAIL"],
                admin_password=SecretStr(values["WEBUI_ADMIN_PASSWORD"]),
                group_name=values["OPEN_WEBUI_ACCESS_GROUP"],
                tool_server_id=values["OPEN_WEBUI_TOOL_SERVER_ID"],
                wait_seconds=float(values.get("OPEN_WEBUI_WAIT_SECONDS", "120")),
                poll_seconds=float(values.get("OPEN_WEBUI_POLL_SECONDS", "2")),
            )
        except (KeyError, ValidationError, ValueError) as exc:
            raise Error(f"invalid Open WebUI configuration: {exc}") from exc


class SignInPayload(BaseModel):
    model_config = ConfigDict(frozen=True, strict=True)

    email: str
    password: str


class SignInResponse(BaseModel):
    model_config = ConfigDict(extra="allow", frozen=True, strict=True)

    token: SecretStr


class GroupShareConfig(BaseModel):
    model_config = ConfigDict(frozen=True, strict=True)

    share: bool = False


class GroupData(BaseModel):
    model_config = ConfigDict(frozen=True, strict=True)

    config: GroupShareConfig = Field(default_factory=GroupShareConfig)


class GroupPayload(BaseModel):
    model_config = ConfigDict(frozen=True, strict=True)

    name: str
    description: str
    data: GroupData = Field(default_factory=GroupData)


class Group(BaseModel):
    model_config = ConfigDict(extra="allow", frozen=True, strict=True)

    id: str = Field(min_length=1)
    name: str


class AccessGrant(BaseModel):
    model_config = ConfigDict(frozen=True, strict=True)

    principal_type: Literal["group", "user"]
    principal_id: str
    permission: Literal["read"]


class ConnectionInfo(BaseModel):
    model_config = ConfigDict(extra="allow", frozen=True, strict=True)

    id: str
    name: str | None = None


class ConnectionConfig(BaseModel):
    model_config = ConfigDict(extra="allow", frozen=True, strict=True)

    enable: bool | None = None
    access_grants: list[AccessGrant] | None = None


class ToolServerConnection(BaseModel):
    model_config = ConfigDict(extra="allow", frozen=True, strict=True)

    type: str
    info: ConnectionInfo
    config: ConnectionConfig = Field(default_factory=ConnectionConfig)


class ToolServerConfiguration(BaseModel):
    model_config = ConfigDict(extra="allow", frozen=True, populate_by_name=True, strict=True)

    connections: list[ToolServerConnection] = Field(alias="TOOL_SERVER_CONNECTIONS")


GROUPS: TypeAdapter[list[Group]] = TypeAdapter(list[Group])


class HttpTransport(Protocol):
    def request(
        self,
        method: str,
        url: str,
        headers: Mapping[str, str],
        payload: object | None = None,
    ) -> object | None: ...


class Waiter(Protocol):
    def monotonic(self) -> float: ...

    def sleep(self, seconds: float) -> None: ...


@dataclass(frozen=True)
class SystemWaiter:
    def monotonic(self) -> float:
        return time.monotonic()

    def sleep(self, seconds: float) -> None:
        time.sleep(seconds)


@dataclass(frozen=True)
class HttpxTransport:
    timeout: float = 10

    def request(
        self,
        method: str,
        url: str,
        headers: Mapping[str, str],
        payload: object | None = None,
    ) -> object | None:
        try:
            response = httpx.request(
                method,
                url,
                headers=headers,
                json=payload,
                timeout=self.timeout,
            )
            response.raise_for_status()
        except httpx.HTTPStatusError as exc:
            path = exc.request.url.path
            raise Error(
                f"{method} {path} failed with HTTP {exc.response.status_code}: {exc.response.text}"
            ) from exc
        except httpx.RequestError as exc:
            raise Error(f"{method} {url} failed: {exc}") from exc
        if not response.content:
            return None
        try:
            return cast(object, response.json())
        except ValueError as exc:
            raise Error(f"{method} {url} returned invalid JSON") from exc


@dataclass
class OpenWebUIClient:
    settings: Settings
    transport: HttpTransport
    token: SecretStr | None = None

    def api(
        self,
        method: str,
        path: str,
        payload: BaseModel | None = None,
        *,
        authenticated: bool = True,
    ) -> object | None:
        headers = {"Accept": "application/json", "Content-Type": "application/json"}
        if authenticated:
            if self.token is None:
                raise Error("Open WebUI API authentication is required")
            headers["Authorization"] = f"Bearer {self.token.get_secret_value()}"
        serialized = (
            None
            if payload is None
            else payload.model_dump(mode="json", by_alias=True, exclude_none=True)
        )
        return self.transport.request(
            method,
            f"{self.settings.base_url}{path}",
            headers,
            serialized,
        )

    def wait_until_ready(self, waiter: Waiter) -> None:
        deadline = waiter.monotonic() + self.settings.wait_seconds
        last_error: Exception | None = None
        while waiter.monotonic() < deadline:
            try:
                self.api("GET", "/health", authenticated=False)
                return
            except Error as exc:
                last_error = exc
                waiter.sleep(self.settings.poll_seconds)
        raise Error(f"timed out waiting for Open WebUI: {last_error}")

    def sign_in(self) -> None:
        try:
            response = SignInResponse.model_validate(
                self.api(
                    "POST",
                    "/api/v1/auths/signin",
                    SignInPayload(
                        email=self.settings.admin_email,
                        password=self.settings.admin_password.get_secret_value(),
                    ),
                    authenticated=False,
                )
            )
        except ValidationError as exc:
            raise Error("Open WebUI sign-in response did not contain a token") from exc
        self.token = response.token

    def ensure_group(self) -> str:
        try:
            groups = GROUPS.validate_python(self.api("GET", "/api/v1/groups/"))
        except ValidationError as exc:
            raise Error(f"invalid Open WebUI groups response: {exc}") from exc

        matches = [group for group in groups if group.name == self.settings.group_name]
        if len(matches) > 1:
            raise Error(f"multiple Open WebUI groups are named {self.settings.group_name!r}")
        if matches:
            return matches[0].id

        try:
            group = Group.model_validate(
                self.api(
                    "POST",
                    "/api/v1/groups/create",
                    GroupPayload(
                        name=self.settings.group_name,
                        description=("Access synchronized from the SSO Paperless group."),
                    ),
                )
            )
        except ValidationError as exc:
            raise Error(f"invalid created Open WebUI group: {exc}") from exc
        if group.name != self.settings.group_name:
            raise Error("Open WebUI did not return the requested group")
        return group.id

    def reconcile_tool_server(self, group_id: str) -> None:
        try:
            current = ToolServerConfiguration.model_validate(
                self.api("GET", "/api/v1/configs/tool_servers")
            )
        except ValidationError as exc:
            raise Error(f"invalid Open WebUI tool server response: {exc}") from exc
        desired = current.model_copy(
            update={
                "connections": with_group_read_grant(
                    current.connections, self.settings.tool_server_id, group_id
                )
            }
        )
        try:
            updated = ToolServerConfiguration.model_validate(
                self.api("POST", "/api/v1/configs/tool_servers", desired)
            )
        except ValidationError as exc:
            raise Error(f"invalid reconciled tool server response: {exc}") from exc
        verify_group_read_grant(updated.connections, self.settings.tool_server_id, group_id)


def matching_connections(
    connections: Sequence[ToolServerConnection], tool_server_id: str
) -> list[ToolServerConnection]:
    return [connection for connection in connections if connection.info.id == tool_server_id]


def desired_grants(group_id: str) -> list[AccessGrant]:
    return [AccessGrant(principal_type="group", principal_id=group_id, permission="read")]


def with_group_read_grant(
    connections: Sequence[ToolServerConnection], tool_server_id: str, group_id: str
) -> list[ToolServerConnection]:
    matches = matching_connections(connections, tool_server_id)
    if len(matches) != 1:
        raise Error(
            f"expected one Open WebUI tool server named {tool_server_id!r}, found {len(matches)}"
        )

    target = matches[0]
    return [
        connection.model_copy(
            update={
                "config": connection.config.model_copy(
                    update={"access_grants": desired_grants(group_id)}
                )
            }
        )
        if connection is target
        else connection
        for connection in connections
    ]


def verify_group_read_grant(
    connections: Sequence[ToolServerConnection], tool_server_id: str, group_id: str
) -> None:
    matches = matching_connections(connections, tool_server_id)
    if len(matches) != 1:
        raise Error(
            f"expected one reconciled Open WebUI tool server named "
            f"{tool_server_id!r}, found {len(matches)}"
        )
    if matches[0].config.access_grants != desired_grants(group_id):
        raise Error("Open WebUI did not retain the requested tool server ACL")


def configure(settings: Settings, client: OpenWebUIClient, waiter: Waiter) -> None:
    client.wait_until_ready(waiter)
    client.sign_in()
    group_id = client.ensure_group()
    client.reconcile_tool_server(group_id)


def main() -> int:
    try:
        settings = Settings.from_environment()
        configure(
            settings,
            OpenWebUIClient(settings, HttpxTransport()),
            SystemWaiter(),
        )
    except Error as exc:
        print(f"open-webui-tool-acl-reconcile: {exc}", file=sys.stderr)
        return 1
    print(
        f"Restricted Open WebUI tool server {settings.tool_server_id!r} "
        f"to group {settings.group_name!r}."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
