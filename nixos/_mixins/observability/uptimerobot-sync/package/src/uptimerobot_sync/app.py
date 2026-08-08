import argparse
import sys
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol, Self, cast

import httpx
from pydantic import (
    BaseModel,
    ConfigDict,
    Field,
    RootModel,
    ValidationError,
    model_validator,
)


class Error(RuntimeError):
    pass


@dataclass(frozen=True)
class Service:
    id: str
    title: str
    url: str


class InventoryService(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True, strict=True)

    id: str = Field(min_length=1)
    title: str = Field(min_length=1)
    url: str = Field(min_length=1)


class Inventory(RootModel[list[InventoryService]]):
    model_config = ConfigDict(frozen=True, strict=True)

    @model_validator(mode="after")
    def validate_unique_fields(self) -> Self:
        for field_name, description in (
            ("id", "id"),
            ("title", "title"),
            ("url", "URL"),
        ):
            values = [getattr(service, field_name) for service in self.root]
            duplicate = next((value for value in values if values.count(value) > 1), None)
            if duplicate is not None:
                raise ValueError(f"duplicate inventory service {description}: {duplicate}")
        return self

    def services(self) -> list[Service]:
        return [
            Service(id=service.id, title=service.title, url=service.url) for service in self.root
        ]


MonitorId = int | str


class Monitor(BaseModel):
    model_config = ConfigDict(extra="allow", frozen=True, populate_by_name=True, strict=True)

    id: MonitorId
    friendly_name: str | None = Field(default=None, alias="friendlyName")
    type: str | None = None
    url: str | None = None
    interval: int | None = None
    timeout: int | None = None


class MonitorList(BaseModel):
    model_config = ConfigDict(extra="allow", frozen=True, strict=True)

    data: list[Monitor]


class MonitorPayload(BaseModel):
    model_config = ConfigDict(frozen=True, populate_by_name=True, strict=True)

    friendly_name: str = Field(alias="friendlyName")
    type: str = "HTTP"
    url: str
    interval: int
    timeout: int = 30


class HttpTransport(Protocol):
    def request(
        self,
        method: str,
        url: str,
        headers: Mapping[str, str],
        payload: object | None = None,
    ) -> object | None: ...


@dataclass(frozen=True)
class HttpxTransport:
    timeout: float = 30

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
            raise Error(
                f"UptimeRobot API {method} {exc.request.url.path} failed with "
                f"HTTP {exc.response.status_code}: {exc.response.text}"
            ) from exc
        except httpx.RequestError as exc:
            raise Error(f"UptimeRobot API {method} {url} failed: {exc}") from exc
        if not response.content:
            return None
        try:
            return cast(object, response.json())
        except ValueError as exc:
            raise Error(f"UptimeRobot API {method} {url} returned invalid JSON") from exc


@dataclass(frozen=True)
class UptimeRobotClient:
    api_url: str
    api_key: str
    transport: HttpTransport

    @property
    def headers(self) -> dict[str, str]:
        return {
            "Authorization": f"Bearer {self.api_key}",
            "Accept": "application/json",
            "Content-Type": "application/json",
        }

    def request(
        self, method: str, path: str, payload: MonitorPayload | None = None
    ) -> object | None:
        serialized = None if payload is None else payload.model_dump(mode="json", by_alias=True)
        return self.transport.request(
            method,
            f"{self.api_url.rstrip('/')}{path}",
            self.headers,
            serialized,
        )

    def list_monitors(self) -> list[Monitor]:
        try:
            return MonitorList.model_validate(self.request("GET", "/monitors")).data
        except ValidationError as exc:
            raise Error(f"UptimeRobot monitor list response is malformed: {exc}") from exc

    def create_monitor(self, payload: MonitorPayload) -> None:
        self.request("POST", "/monitors", payload)

    def update_monitor(self, monitor_id: MonitorId, payload: MonitorPayload) -> None:
        self.request("PATCH", f"/monitors/{monitor_id}", payload)

    def delete_monitor(self, monitor_id: MonitorId) -> None:
        self.request("DELETE", f"/monitors/{monitor_id}")


class MonitorClient(Protocol):
    def list_monitors(self) -> list[Monitor]: ...

    def create_monitor(self, payload: MonitorPayload) -> None: ...

    def update_monitor(self, monitor_id: MonitorId, payload: MonitorPayload) -> None: ...

    def delete_monitor(self, monitor_id: MonitorId) -> None: ...


def load_services(path: Path) -> list[Service]:
    try:
        return Inventory.model_validate_json(path.read_text(encoding="utf-8")).services()
    except OSError as exc:
        raise Error(f"cannot read inventory JSON: {exc}") from exc
    except ValidationError as exc:
        raise Error(f"invalid inventory JSON: {exc}") from exc


def desired_monitor(service: Service, interval: int) -> MonitorPayload:
    return MonitorPayload(
        friendly_name=service.title,
        url=service.url,
        interval=interval,
    )


def monitor_matches(monitor: Monitor, desired: MonitorPayload) -> bool:
    return (
        monitor.friendly_name == desired.friendly_name
        and monitor.type == desired.type
        and monitor.url == desired.url
        and monitor.interval == desired.interval
        and monitor.timeout == desired.timeout
    )


def reconcile(
    client: MonitorClient,
    services: Sequence[Service],
    interval: int,
    *,
    dry_run: bool = False,
) -> list[str]:
    if interval <= 0:
        raise Error("monitor interval must be positive")

    unmatched: dict[MonitorId, Monitor] = {}
    for monitor in client.list_monitors():
        if monitor.id in unmatched:
            raise Error(f"UptimeRobot returned duplicate monitor id {monitor.id}")
        unmatched[monitor.id] = monitor

    actions: list[str] = []
    for service in services:
        candidates = [monitor for monitor in unmatched.values() if monitor.url == service.url]
        if not candidates:
            candidates = [
                monitor for monitor in unmatched.values() if monitor.friendly_name == service.title
            ]
        if len(candidates) > 1:
            raise Error(f"cannot adopt {service.id}: multiple monitors match its URL or title")
        matched_monitor = candidates[0] if candidates else None
        desired = desired_monitor(service, interval)
        if matched_monitor is None:
            actions.append(f"create {service.id} ({service.url})")
            if not dry_run:
                client.create_monitor(desired)
            continue

        del unmatched[matched_monitor.id]
        if not monitor_matches(matched_monitor, desired):
            actions.append(f"update {service.id} ({matched_monitor.id})")
            if not dry_run:
                client.update_monitor(matched_monitor.id, desired)

    for monitor_id, monitor in sorted(unmatched.items(), key=lambda item: str(item[0])):
        label = monitor.friendly_name or monitor.url or "unnamed"
        actions.append(f"delete {label} ({monitor_id})")
        if not dry_run:
            client.delete_monitor(monitor_id)

    return actions


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="uptimerobot-sync",
        description="Reconcile UptimeRobot HTTP monitors with Nix service inventory.",
    )
    parser.add_argument("--api-url", default="https://api.uptimerobot.com/v3")
    parser.add_argument("--api-key-file", required=True, type=Path)
    parser.add_argument("--inventory-json-file", required=True, type=Path)
    parser.add_argument("--interval", type=int, default=300)
    parser.add_argument("--dry-run", action="store_true")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        api_key = args.api_key_file.read_text(encoding="utf-8").strip()
        if not api_key:
            raise Error("API key file is empty")
        actions = reconcile(
            UptimeRobotClient(args.api_url, api_key, HttpxTransport()),
            load_services(args.inventory_json_file),
            args.interval,
            dry_run=args.dry_run,
        )
    except (OSError, Error) as exc:
        print(f"uptimerobot-sync: {exc}", file=sys.stderr)
        return 1

    if actions:
        for action in actions:
            print(action)
    else:
        print("UptimeRobot monitors are already in sync")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
