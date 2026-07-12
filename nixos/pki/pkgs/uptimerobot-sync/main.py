#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any


MANAGED_TAG = "nix-inventory"
SERVICE_TAG_PREFIX = "nix-service-"


class UptimeRobotError(RuntimeError):
    pass


@dataclass(frozen=True)
class Service:
    id: str
    title: str
    url: str

    @property
    def service_tag(self) -> str:
        return f"{SERVICE_TAG_PREFIX}{self.id}"


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="uptimerobot-sync",
        description="Reconcile UptimeRobot HTTP monitors with Nix service inventory.",
    )
    parser.add_argument(
        "--api-url",
        default="https://api.uptimerobot.com/v3",
        help="UptimeRobot API base URL.",
    )
    parser.add_argument(
        "--api-key-file",
        required=True,
        help="File containing an UptimeRobot main API key.",
    )
    parser.add_argument(
        "--inventory-json-file",
        required=True,
        help="JSON file containing inventory services.",
    )
    parser.add_argument(
        "--interval",
        type=int,
        default=300,
        help="Monitor interval in seconds.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print planned changes without applying them.",
    )
    return parser


def load_services(path: str) -> list[Service]:
    try:
        document = json.loads(Path(path).read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise UptimeRobotError(f"cannot read inventory JSON: {error}") from error

    if not isinstance(document, list):
        raise UptimeRobotError("inventory JSON must be an array")

    services: list[Service] = []
    seen_ids: set[str] = set()
    seen_urls: set[str] = set()
    for entry in document:
        if not isinstance(entry, dict):
            raise UptimeRobotError("each inventory service must be an object")
        try:
            service = Service(
                id=str(entry["id"]),
                title=str(entry["title"]),
                url=str(entry["url"]),
            )
        except KeyError as error:
            raise UptimeRobotError(
                f"inventory service is missing {error.args[0]}"
            ) from error
        if not service.id or not service.title or not service.url:
            raise UptimeRobotError("inventory service fields must not be empty")
        if service.id in seen_ids:
            raise UptimeRobotError(f"duplicate inventory service id: {service.id}")
        if service.url in seen_urls:
            raise UptimeRobotError(f"duplicate inventory service URL: {service.url}")
        seen_ids.add(service.id)
        seen_urls.add(service.url)
        services.append(service)
    return services


def tag_names(monitor: dict[str, Any]) -> set[str]:
    names: set[str] = set()
    for tag in monitor.get("tags") or []:
        if isinstance(tag, str):
            names.add(tag)
        elif isinstance(tag, dict) and isinstance(tag.get("name"), str):
            names.add(tag["name"])
    return names


def monitor_service_id(monitor: dict[str, Any]) -> str | None:
    service_tags = sorted(
        tag.removeprefix(SERVICE_TAG_PREFIX)
        for tag in tag_names(monitor)
        if tag.startswith(SERVICE_TAG_PREFIX)
    )
    if len(service_tags) > 1:
        raise UptimeRobotError(
            f"monitor {monitor.get('id')} has multiple inventory service tags"
        )
    return service_tags[0] if service_tags else None


class UptimeRobotClient:
    def __init__(self, api_url: str, api_key: str):
        self.api_url = api_url.rstrip("/")
        self.api_key = api_key

    def request(
        self,
        method: str,
        path: str,
        payload: dict[str, Any] | None = None,
    ) -> Any:
        data = None if payload is None else json.dumps(payload).encode()
        request = urllib.request.Request(
            f"{self.api_url}{path}",
            data=data,
            method=method,
            headers={
                "Authorization": f"Bearer {self.api_key}",
                "Accept": "application/json",
                "Content-Type": "application/json",
            },
        )
        for attempt in range(4):
            try:
                with urllib.request.urlopen(request, timeout=30) as response:
                    body = response.read()
            except urllib.error.HTTPError as error:
                if error.code == 429 and attempt < 3:
                    retry_after = error.headers.get("Retry-After", "1")
                    try:
                        delay = max(1, int(retry_after))
                    except ValueError:
                        delay = 1
                    error.close()
                    time.sleep(delay)
                    continue
                detail = error.read().decode(errors="replace")
                raise UptimeRobotError(
                    f"UptimeRobot API {method} {path} failed with HTTP {error.code}: {detail}"
                ) from error
            except urllib.error.URLError as error:
                raise UptimeRobotError(
                    f"UptimeRobot API {method} {path} failed: {error.reason}"
                ) from error
            try:
                return json.loads(body) if body else None
            except json.JSONDecodeError as error:
                raise UptimeRobotError(
                    f"UptimeRobot API {method} {path} returned invalid JSON"
                ) from error
        raise AssertionError("unreachable")

    def list_monitors(self) -> list[dict[str, Any]]:
        response = self.request("GET", "/monitors")
        if not isinstance(response, dict) or not isinstance(
            response.get("monitors"), list
        ):
            raise UptimeRobotError("UptimeRobot monitor list response is malformed")
        return response["monitors"]

    def create_monitor(self, payload: dict[str, Any]) -> None:
        self.request("POST", "/monitors", payload)

    def update_monitor(self, monitor_id: Any, payload: dict[str, Any]) -> None:
        self.request("PATCH", f"/monitors/{monitor_id}", payload)

    def delete_monitor(self, monitor_id: Any) -> None:
        self.request("DELETE", f"/monitors/{monitor_id}")


def reconcile(
    client: Any,
    services: list[Service],
    interval: int,
    dry_run: bool = False,
) -> list[str]:
    if interval <= 0:
        raise UptimeRobotError("monitor interval must be positive")

    monitors = client.list_monitors()
    by_service_id: dict[str, dict[str, Any]] = {}
    by_url: dict[str, list[dict[str, Any]]] = {}
    for monitor in monitors:
        if not isinstance(monitor, dict):
            raise UptimeRobotError("UptimeRobot returned a non-object monitor")
        by_url.setdefault(str(monitor.get("url", "")), []).append(monitor)
        service_id = monitor_service_id(monitor)
        if MANAGED_TAG in tag_names(monitor) and service_id is not None:
            if service_id in by_service_id:
                raise UptimeRobotError(
                    f"multiple managed monitors claim inventory service {service_id}"
                )
            by_service_id[service_id] = monitor

    actions: list[str] = []
    desired_ids = {service.id for service in services}
    for service in services:
        monitor = by_service_id.get(service.id)
        if monitor is None:
            candidates = by_url.get(service.url, [])
            if len(candidates) > 1:
                raise UptimeRobotError(
                    f"cannot adopt {service.id}: multiple monitors use {service.url}"
                )
            monitor = candidates[0] if candidates else None

        if monitor is None:
            payload = {
                "friendlyName": service.title,
                "type": "HTTP",
                "url": service.url,
                "interval": interval,
                "tagNames": [MANAGED_TAG, service.service_tag],
            }
            actions.append(f"create {service.id} ({service.url})")
            if not dry_run:
                client.create_monitor(payload)
            continue

        tags = tag_names(monitor) | {MANAGED_TAG, service.service_tag}
        desired = {
            "friendlyName": service.title,
            "type": "HTTP",
            "url": service.url,
            "interval": interval,
            "tagNames": sorted(tags),
        }
        changes = {
            key: value
            for key, value in desired.items()
            if (tag_names(monitor) if key == "tagNames" else monitor.get(key))
            != (set(value) if key == "tagNames" else value)
        }
        if changes:
            actions.append(f"update {service.id} ({monitor.get('id')})")
            if not dry_run:
                client.update_monitor(monitor.get("id"), desired)

    for service_id, monitor in sorted(by_service_id.items()):
        if service_id in desired_ids:
            continue
        actions.append(f"delete {service_id} ({monitor.get('id')})")
        if not dry_run:
            client.delete_monitor(monitor.get("id"))

    return actions


def main() -> int:
    args = build_parser().parse_args()
    try:
        api_key = Path(args.api_key_file).read_text().strip()
        if not api_key:
            raise UptimeRobotError("API key file is empty")
        services = load_services(args.inventory_json_file)
        actions = reconcile(
            UptimeRobotClient(args.api_url, api_key),
            services,
            args.interval,
            args.dry_run,
        )
    except (OSError, UptimeRobotError) as error:
        print(f"uptimerobot-sync: {error}", file=sys.stderr)
        return 1

    if actions:
        for action in actions:
            print(action)
    else:
        print("UptimeRobot monitors are already in sync")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
