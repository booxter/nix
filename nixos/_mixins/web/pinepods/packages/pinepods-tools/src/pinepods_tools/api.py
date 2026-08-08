from __future__ import annotations

from collections.abc import Mapping

import httpx

from .models import (
    BackupFilesResponse,
    CreateAdminRequest,
    CreateAdminResponse,
    DeleteBackupRequest,
    SelfServiceStatus,
    StartBackupResponse,
    TaskResponse,
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

    @staticmethod
    def _headers(api_key: str) -> dict[str, str]:
        return {"Api-Key": api_key}

    def start_backup(self, api_key: str) -> StartBackupResponse:
        response = self._response(
            "POST",
            "/api/data/manual_backup_to_directory",
            headers=self._headers(api_key),
            json={},
        )
        try:
            return StartBackupResponse.model_validate(response.json())
        except ValueError as error:
            raise PinepodsApiError("PinePods did not return a backup task ID") from error

    def task(self, task_id: str) -> TaskResponse:
        response = self._response("GET", f"/api/tasks/{task_id}")
        try:
            return TaskResponse.model_validate(response.json())
        except ValueError as error:
            raise PinepodsApiError("PinePods returned invalid backup task state") from error

    def backup_files(self, api_key: str) -> BackupFilesResponse:
        response = self._response(
            "POST",
            "/api/data/list_backup_files",
            headers=self._headers(api_key),
            json={},
        )
        try:
            return BackupFilesResponse.model_validate(response.json())
        except ValueError as error:
            raise PinepodsApiError("PinePods returned an invalid backup file list") from error

    def delete_backup(self, api_key: str, filename: str) -> None:
        request = DeleteBackupRequest(backup_filename=filename)
        self._response(
            "POST",
            "/api/data/delete_backup_file",
            headers=self._headers(api_key),
            json=request.model_dump(),
        )
