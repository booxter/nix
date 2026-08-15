from __future__ import annotations

from collections.abc import Mapping

import httpx

from .models import (
    CreateAdminRequest,
    CreateAdminResponse,
    SelfServiceStatus,
)


class PinepodsApiError(RuntimeError):
    pass


class PinepodsApi:
    def __init__(self, client: httpx.Client) -> None:
        self.client = client

    def _response(
        self,
        method: str,
        path: str,
        *,
        headers: Mapping[str, str] | None = None,
        json: object | None = None,
    ) -> httpx.Response:
        try:
            response = self.client.request(method, path, headers=headers, json=json)
            response.raise_for_status()
            return response
        except httpx.HTTPError as error:
            raise PinepodsApiError(f"PinePods API request failed: {method} {path}") from error

    def self_service_status(self) -> SelfServiceStatus:
        response = self._response("GET", "/api/data/self_service_status")
        try:
            return SelfServiceStatus.model_validate(response.json())
        except ValueError as error:
            raise PinepodsApiError("PinePods returned invalid self-service status") from error

    def create_admin(self, request: CreateAdminRequest) -> CreateAdminResponse:
        response = self._response("POST", "/api/data/create_first", json=request.model_dump())
        try:
            return CreateAdminResponse.model_validate(response.json())
        except ValueError as error:
            raise PinepodsApiError(
                "PinePods did not return the created administrator ID"
            ) from error
