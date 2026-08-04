from __future__ import annotations

import json
import os
import subprocess
from collections.abc import Callable, Iterable, Mapping, Sequence
from dataclasses import dataclass
from typing import Protocol, cast

from b2sdk.v2 import B2Api  # type: ignore[import-untyped]
from b2sdk.v2.exception import B2Error  # type: ignore[import-untyped]
from pydantic import ValidationError

from .errors import CollectionFailure
from .models import BucketUsage, RepositoryConfig, ResticStats


class BucketUsageClient(Protocol):
    def usage(self, bucket_name: str) -> BucketUsage: ...


class _FileVersion(Protocol):
    size: int


class _Bucket(Protocol):
    def ls(
        self,
        folder_to_list: str = "",
        latest_only: bool = True,
        recursive: bool = False,
    ) -> Iterable[tuple[_FileVersion, str]]: ...


class _B2Api(Protocol):
    def authorize_account(
        self, realm: str, application_key_id: str, application_key: str
    ) -> object: ...

    def list_buckets(self, bucket_name: str) -> Sequence[_Bucket]: ...


def _create_b2_api() -> _B2Api:
    return cast(_B2Api, B2Api())


@dataclass(frozen=True)
class B2SdkBucketUsageClient:
    application_key_id: str
    application_key: str
    api_factory: Callable[[], _B2Api] = _create_b2_api

    def usage(self, bucket_name: str) -> BucketUsage:
        try:
            api = self.api_factory()
            api.authorize_account("production", self.application_key_id, self.application_key)
            buckets = api.list_buckets(bucket_name=bucket_name)
            if not buckets:
                raise CollectionFailure(1)
            file_count = 0
            total_size = 0
            for file_version, _folder in buckets[0].ls(
                "",
                latest_only=False,
                recursive=True,
            ):
                file_count += 1
                total_size += file_version.size
            return BucketUsage(total_size_bytes=total_size, file_count=file_count)
        except B2Error as error:
            raise CollectionFailure(1) from error


@dataclass(frozen=True)
class CommandResult:
    returncode: int
    stdout: str
    stderr: str = ""


class CommandRunner(Protocol):
    def run(self, arguments: Sequence[str], environment: Mapping[str, str]) -> CommandResult: ...


@dataclass(frozen=True)
class SubprocessRunner:
    def run(self, arguments: Sequence[str], environment: Mapping[str, str]) -> CommandResult:
        try:
            process = subprocess.run(
                arguments,
                check=False,
                capture_output=True,
                text=True,
                env=environment,
            )
        except OSError:
            return CommandResult(127, "")
        return CommandResult(process.returncode, process.stdout, process.stderr)


class RepositoryUsageClient(Protocol):
    def stats(self, repository: RepositoryConfig) -> ResticStats: ...


@dataclass(frozen=True)
class ResticRepositoryUsageClient:
    runner: CommandRunner
    environment: Mapping[str, str]
    cache_dir: str
    retry_lock: str

    def stats(self, repository: RepositoryConfig) -> ResticStats:
        result = self.runner.run(
            [
                "restic",
                "-r",
                repository.repository,
                "--password-file",
                str(repository.password_file),
                "--cache-dir",
                self.cache_dir,
                "--retry-lock",
                self.retry_lock,
                "stats",
                "--mode",
                "raw-data",
                "--json",
            ],
            self.environment,
        )
        if result.returncode != 0:
            raise CollectionFailure(result.returncode)
        try:
            return ResticStats.model_validate(json.loads(result.stdout))
        except (json.JSONDecodeError, ValidationError) as error:
            raise CollectionFailure(1) from error


def restic_environment(
    environment: Mapping[str, str],
    *,
    application_key_id: str,
    application_key: str,
    cache_dir: str,
) -> dict[str, str]:
    return {
        **environment,
        "B2_ACCOUNT_ID": application_key_id,
        "B2_ACCOUNT_KEY": application_key,
        "RESTIC_CACHE_DIR": cache_dir,
    }


def system_environment() -> Mapping[str, str]:
    return os.environ
