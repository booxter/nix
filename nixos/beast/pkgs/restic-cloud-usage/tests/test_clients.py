from __future__ import annotations

from collections.abc import Mapping, Sequence
from dataclasses import dataclass, field
import json
from pathlib import Path

import pytest

from restic_cloud_usage.clients import (
    B2SdkBucketUsageClient,
    CommandResult,
    ResticRepositoryUsageClient,
    restic_environment,
)
from restic_cloud_usage.errors import CollectionFailure
from restic_cloud_usage.models import RepositoryConfig


@dataclass
class RecordingRunner:
    result: CommandResult
    calls: list[tuple[tuple[str, ...], Mapping[str, str]]] = field(default_factory=list)

    def run(self, arguments: Sequence[str], environment: Mapping[str, str]) -> CommandResult:
        self.calls.append((tuple(arguments), environment))
        return self.result


@dataclass(frozen=True)
class FileVersion:
    size: int


@dataclass
class Bucket:
    calls: list[tuple[str, bool, bool]] = field(default_factory=list)

    def ls(
        self,
        folder_to_list: str = "",
        latest_only: bool = True,
        recursive: bool = False,
    ) -> Sequence[tuple[FileVersion, str]]:
        self.calls.append((folder_to_list, latest_only, recursive))
        return ((FileVersion(10), ""), (FileVersion(15), ""))


@dataclass
class Api:
    bucket: Bucket
    authorization: tuple[str, str, str] | None = None
    requested_bucket: str | None = None

    def authorize_account(
        self,
        realm: str,
        application_key_id: str,
        application_key: str,
    ) -> object:
        self.authorization = (realm, application_key_id, application_key)
        return object()

    def list_buckets(self, bucket_name: str) -> Sequence[Bucket]:
        self.requested_bucket = bucket_name
        return (self.bucket,)


@dataclass(frozen=True)
class ApiFactory:
    api: Api

    def __call__(self) -> Api:
        return self.api


def repository() -> RepositoryConfig:
    return RepositoryConfig(
        name="srvarr",
        backupJob="restic-srvarr-cloud-offload",
        backupTitle="srvarr Cloud Offload",
        bucket="backups",
        prefix="hosts/srvarr",
        repository="b2:backups:hosts/srvarr",
        passwordFile=Path("/run/secrets/password"),
    )


def test_restic_client_uses_existing_stats_workflow() -> None:
    runner = RecordingRunner(
        CommandResult(
            0,
            json.dumps(
                {
                    "total_size": 10,
                    "total_uncompressed_size": 20,
                    "total_blob_count": 3,
                    "snapshots_count": 4,
                }
            ),
        )
    )
    client = ResticRepositoryUsageClient(runner, {"B2_ACCOUNT_ID": "id"}, "/cache", "5m")

    stats = client.stats(repository())

    assert stats.total_size == 10
    assert runner.calls == [
        (
            (
                "restic",
                "-r",
                "b2:backups:hosts/srvarr",
                "--password-file",
                "/run/secrets/password",
                "--cache-dir",
                "/cache",
                "--retry-lock",
                "5m",
                "stats",
                "--mode",
                "raw-data",
                "--json",
            ),
            {"B2_ACCOUNT_ID": "id"},
        )
    ]


def test_b2_client_matches_show_size_version_traversal() -> None:
    bucket = Bucket()
    api = Api(bucket)

    usage = B2SdkBucketUsageClient("id", "key", ApiFactory(api)).usage("backups")

    assert usage.total_size_bytes == 25
    assert usage.file_count == 2
    assert api.authorization == ("production", "id", "key")
    assert api.requested_bucket == "backups"
    assert bucket.calls == [("", False, True)]


@pytest.mark.parametrize(
    ("result", "exit_code"),
    [(CommandResult(23, ""), 23), (CommandResult(0, "not json"), 1)],
)
def test_restic_client_reports_collection_failures(
    result: CommandResult,
    exit_code: int,
) -> None:
    with pytest.raises(CollectionFailure) as raised:
        ResticRepositoryUsageClient(RecordingRunner(result), {}, "/cache", "5m").stats(repository())

    assert raised.value.exit_code == exit_code


def test_restic_environment_preserves_parent_and_adds_credentials() -> None:
    assert restic_environment(
        {"PATH": "/bin"},
        application_key_id="id",
        application_key="key",
        cache_dir="/cache",
    ) == {
        "PATH": "/bin",
        "B2_ACCOUNT_ID": "id",
        "B2_ACCOUNT_KEY": "key",
        "RESTIC_CACHE_DIR": "/cache",
    }
