from pathlib import Path
from typing import Annotated

from pydantic import BaseModel, ConfigDict, StringConstraints, ValidationError

from sync_repo.git import RepositorySpec

NonEmptyString = Annotated[str, StringConstraints(min_length=1)]


class RepositoryConfiguration(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    remote: NonEmptyString
    path: Path


class SyncConfiguration(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    repositories: dict[str, RepositoryConfiguration]


class ConfigurationError(Exception):
    """A sync-repo configuration could not be loaded."""


def load_repository_specs(path: Path) -> dict[str, RepositorySpec]:
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as error:
        raise ConfigurationError(f"cannot read configuration {path}: {error}") from error

    try:
        configuration = SyncConfiguration.model_validate_json(text)
    except ValidationError as error:
        raise ConfigurationError(f"invalid configuration {path}: {error}") from error

    return {
        name: RepositorySpec(name=name, remote=repository.remote, path=repository.path)
        for name, repository in configuration.repositories.items()
    }
