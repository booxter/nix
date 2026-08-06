from __future__ import annotations

from pydantic import BaseModel, ConfigDict, Field, RootModel


class PackageTarget(BaseModel):
    model_config = ConfigDict(extra="forbid", populate_by_name=True)

    attr: str = Field(min_length=1)
    system: str = "x86_64-linux"
    nix_update_system: str | None = Field(default=None, alias="nixUpdateSystem")
    nix_update_args: tuple[str, ...] = Field(default=(), alias="nixUpdateArgs")

    @property
    def update_system(self) -> str:
        return self.nix_update_system or self.system


class PackageTargets(BaseModel):
    model_config = ConfigDict(extra="forbid")

    targets: tuple[PackageTarget, ...]


class OciPin(BaseModel):
    model_config = ConfigDict(extra="forbid", populate_by_name=True)

    image: str = Field(min_length=1)
    tag: str = Field(min_length=1)
    digest: str = Field(min_length=1)
    hash: str = Field(min_length=1)
    tag_regex: str = Field(
        default=r"^[0-9]+\.[0-9]+\.[0-9]+$",
        alias="tagRegex",
    )
    changelog: str = ""


class OciPins(RootModel[dict[str, OciPin]]):
    pass


class PrefetchedImage(BaseModel):
    model_config = ConfigDict(extra="ignore", populate_by_name=True)

    image_digest: str = Field(alias="imageDigest", min_length=1)
    hash: str = Field(min_length=1)


class SkopeoTags(BaseModel):
    model_config = ConfigDict(extra="ignore", populate_by_name=True)

    tags: tuple[str, ...] = Field(alias="Tags")


class ImageLabels(BaseModel):
    model_config = ConfigDict(extra="ignore", populate_by_name=True)

    labels: dict[str, str] = Field(default_factory=dict, alias="Labels")


class ImageConfig(BaseModel):
    model_config = ConfigDict(extra="ignore", populate_by_name=True)

    config: ImageLabels = Field(default_factory=ImageLabels)
    labels: dict[str, str] = Field(default_factory=dict, alias="Labels")

    def merged_labels(self) -> dict[str, str]:
        return self.labels | self.config.labels
