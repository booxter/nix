from __future__ import annotations

import argparse
import sys
from collections.abc import Mapping
from pathlib import Path
from typing import Protocol

import httpx
from pydantic import BaseModel, Field, StrictBool, TypeAdapter

from .api import PinepodsApiError
from .cli import api_client
from .service import read_secret


class User(BaseModel):
    retrieved_id: int = Field(strict=True, gt=0)


class Podcast(BaseModel):
    podcastid: int = Field(strict=True, gt=0)


class Podcasts(BaseModel):
    pods: list[Podcast]


class Enabled(BaseModel):
    enabled: StrictBool


class AutoDownload(BaseModel):
    auto_download: StrictBool


class SubscriptionApi(Protocol):
    def user_id(self) -> int: ...
    def downloads_enabled(self) -> bool: ...
    def podcasts(self, user_id: int) -> list[int]: ...
    def ensure_settings(self, user_id: int, podcast_id: int) -> None: ...


class HttpSubscriptionApi:
    def __init__(self, client: httpx.Client, api_key: str) -> None:
        self.client = client
        self.headers = {"Api-Key": api_key}

    def request(
        self,
        method: str,
        endpoint: str,
        *,
        params: dict[str, int] | None = None,
        json: Mapping[str, int | bool] | None = None,
    ) -> object:
        try:
            response = self.client.request(
                method, f"/api/data/{endpoint}", headers=self.headers, params=params, json=json
            )
            response.raise_for_status()
            return response.json()
        except (httpx.HTTPError, ValueError) as error:
            raise PinepodsApiError(f"PinePods API request failed: {endpoint}") from error

    def user_id(self) -> int:
        return self.parse(User, self.request("GET", "get_user"), "get_user").retrieved_id

    def downloads_enabled(self) -> bool:
        result = self.request("GET", "download_status")
        try:
            return TypeAdapter(StrictBool).validate_python(result)
        except ValueError as error:
            raise PinepodsApiError("Invalid PinePods download status") from error

    def podcasts(self, user_id: int) -> list[int]:
        endpoint = f"return_pods/{user_id}"
        result = self.parse(Podcasts, self.request("GET", endpoint), endpoint)
        return [podcast.podcastid for podcast in result.pods]

    @staticmethod
    def parse[T: BaseModel](model: type[T], value: object, endpoint: str) -> T:
        try:
            return model.model_validate(value)
        except ValueError as error:
            raise PinepodsApiError(f"Invalid PinePods response: {endpoint}") from error

    def ensure_settings(self, user_id: int, podcast_id: int) -> None:
        ids = {"user_id": user_id, "podcast_id": podcast_id}
        try:
            status = self.parse(
                AutoDownload,
                self.request("POST", "get_auto_download_status", json=ids),
                "get_auto_download_status",
            )
            if not status.auto_download:
                self.request("POST", "enable_auto_download", json={**ids, "auto_download": True})

            for setting in ("auto_transcribe", "auto_ad_detect", "ad_skip_auto_activate"):
                endpoint = f"get_{setting}"
                status_enabled = self.parse(
                    Enabled, self.request("GET", endpoint, params=ids), endpoint
                )
                if not status_enabled.enabled:
                    self.request("POST", f"adjust_{setting}", json={**ids, "enabled": True})
        except PinepodsApiError as error:
            raise PinepodsApiError(f"Podcast {podcast_id}: {error}") from error


def enforce(api: SubscriptionApi) -> int:
    user_id = api.user_id()
    if not api.downloads_enabled():
        raise PinepodsApiError("PinePods global downloads are disabled")
    podcasts = api.podcasts(user_id)
    for podcast_id in podcasts:
        api.ensure_settings(user_id, podcast_id)
    return len(podcasts)


def main() -> None:
    parser = argparse.ArgumentParser(description="Enable automatic processing for subscriptions")
    parser.add_argument("--url", required=True)
    parser.add_argument("--api-key-file", required=True)
    args = parser.parse_args()
    try:
        api_key = read_secret(Path(args.api_key_file))
        if not api_key:
            raise PinepodsApiError("PinePods API key is empty")
        with api_client(args.url) as client:
            count = enforce(HttpSubscriptionApi(client, api_key))
    except (PinepodsApiError, OSError, httpx.InvalidURL) as error:
        print(f"PinePods subscription enforcement failed: {error}", file=sys.stderr)
        raise SystemExit(1) from error
    print(f"Checked {count} PinePods subscriptions")
