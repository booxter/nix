#!/usr/bin/env python3

import asyncio
import json
import time
import urllib.error
import urllib.parse
import urllib.request

import websockets


BASE_URL = "@baseUrl@"
CLIENT_ID = "@clientId@"
OWNER_USERNAME = "@ownerUsername@"
PASSWORD_FILE = "@passwordFile@"
KEEP_BACKUPS = 7


def post(path, payload, *, form=False):
    if form:
        body = urllib.parse.urlencode(payload).encode()
        content_type = "application/x-www-form-urlencoded"
    else:
        body = json.dumps(payload).encode()
        content_type = "application/json"
    request = urllib.request.Request(
        f"{BASE_URL}{path}",
        data=body,
        headers={"Content-Type": content_type},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def login():
    with open(PASSWORD_FILE, encoding="utf-8") as password_stream:
        password = password_stream.read().rstrip("\n")

    deadline = time.monotonic() + 300
    while True:
        try:
            flow = post(
                "/auth/login_flow",
                {
                    "client_id": CLIENT_ID,
                    "handler": ["homeassistant", None],
                    "redirect_uri": CLIENT_ID,
                },
            )
            break
        except (OSError, urllib.error.HTTPError):
            if time.monotonic() >= deadline:
                raise
            time.sleep(2)

    login_result = post(
        f"/auth/login_flow/{flow['flow_id']}",
        {
            "client_id": CLIENT_ID,
            "username": OWNER_USERNAME,
            "password": password,
        },
    )
    token = post(
        "/auth/token",
        {
            "client_id": CLIENT_ID,
            "grant_type": "authorization_code",
            "code": login_result["result"],
        },
        form=True,
    )
    return token["access_token"]


async def run_backup(access_token):
    websocket_url = BASE_URL.replace("http://", "ws://", 1) + "/api/websocket"
    async with websockets.connect(websocket_url, open_timeout=30) as websocket:
        auth_required = json.loads(await websocket.recv())
        if auth_required.get("type") != "auth_required":
            raise RuntimeError(f"unexpected authentication greeting: {auth_required}")
        await websocket.send(json.dumps({"type": "auth", "access_token": access_token}))
        auth_result = json.loads(await websocket.recv())
        if auth_result.get("type") != "auth_ok":
            raise RuntimeError(f"Home Assistant authentication failed: {auth_result}")

        command_id = 0

        async def command(message):
            nonlocal command_id
            command_id += 1
            message = {"id": command_id, **message}
            await websocket.send(json.dumps(message))
            response = json.loads(await websocket.recv())
            if response.get("id") != command_id:
                raise RuntimeError(f"unexpected WebSocket response: {response}")
            if not response.get("success"):
                raise RuntimeError(f"Home Assistant command failed: {response}")
            return response.get("result")

        before = await command({"type": "backup/info"})
        previous_ids = {backup["backup_id"] for backup in before["backups"]}
        await command(
            {
                "type": "backup/generate",
                "agent_ids": ["backup.local"],
                "include_database": True,
                "include_homeassistant": True,
                "name": "Nix scheduled backup",
            }
        )

        deadline = time.monotonic() + 7200
        while True:
            await asyncio.sleep(2)
            info = await command({"type": "backup/info"})
            new_backups = [
                backup
                for backup in info["backups"]
                if backup["backup_id"] not in previous_ids
                and "backup.local" in backup["agents"]
                and backup["database_included"]
                and backup["homeassistant_included"]
            ]
            if new_backups:
                break
            if info["state"] == "idle":
                raise RuntimeError(
                    f"Home Assistant backup stopped without a local archive: "
                    f"{info['last_action_event']}"
                )
            if time.monotonic() >= deadline:
                raise TimeoutError("Home Assistant native backup timed out")

        local_backups = sorted(
            (
                backup
                for backup in info["backups"]
                if "backup.local" in backup["agents"]
            ),
            key=lambda backup: backup["date"],
            reverse=True,
        )
        for backup in local_backups[KEEP_BACKUPS:]:
            await command({"type": "backup/delete", "backup_id": backup["backup_id"]})


asyncio.run(run_backup(login()))
