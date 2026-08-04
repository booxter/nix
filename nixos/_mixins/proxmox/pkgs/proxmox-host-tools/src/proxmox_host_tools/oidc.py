from __future__ import annotations

import argparse
import sys
from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import TextIO

from pydantic import AliasChoices, BaseModel, ConfigDict, Field, TypeAdapter, ValidationError

from proxmox_host_tools.certificate import Error, Pmxcfs
from proxmox_host_tools.process import Runner, SubprocessRunner


class OidcConfig(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True, strict=True)

    pveum: Path
    pmxcfs_directory: Path
    client_secret_file: Path
    realm: str = Field(min_length=1)
    issuer_url: str = Field(min_length=1)
    client_id: str = Field(min_length=1)
    autocreate_users: bool
    groups_claim: str = Field(min_length=1)
    autocreate_groups: bool
    overwrite_groups: bool
    scopes: tuple[str, ...] = Field(min_length=1)
    comment: str
    username_claim: str = Field(min_length=1)
    mapped_group: str = Field(min_length=1)
    group_comment: str
    acl_path: str = Field(min_length=1)
    role: str = Field(min_length=1)


class ListedEntry(BaseModel):
    model_config = ConfigDict(extra="allow", strict=True)

    identifier: str = Field(
        validation_alias=AliasChoices("realm", "realmid", "groupid", "group", "id")
    )


_LISTED_ENTRIES = TypeAdapter(list[ListedEntry])


def binary(value: bool) -> str:
    return "1" if value else "0"


def read_secret(path: Path) -> str:
    try:
        secret = path.read_text().strip()
    except OSError as error:
        raise Error(f"failed to read Proxmox OIDC client secret from {path}") from error
    if not secret:
        raise Error(f"Proxmox OIDC client secret is empty: {path}")
    return secret


@dataclass(frozen=True)
class PveumClient:
    runner: Runner
    executable: tuple[str, ...]

    def listed(self, resource: str) -> set[str]:
        output = self._run(resource, "list", "--output-format", "json")
        try:
            return {entry.identifier for entry in _LISTED_ENTRIES.validate_json(output)}
        except ValidationError as error:
            raise Error(f"invalid pveum {resource} list: {error}") from error

    def run(self, *arguments: str) -> None:
        self._run(*arguments)

    def _run(self, *arguments: str) -> str:
        result = self.runner.run([*self.executable, *arguments])
        if result.returncode != 0:
            detail = result.stderr.strip()
            suffix = f": {detail}" if detail else ""
            raise Error(f"pveum operation failed{suffix}")
        return result.stdout


def configure_oidc(
    config: OidcConfig,
    pveum: PveumClient,
    pmxcfs: Pmxcfs,
    stderr: TextIO,
) -> None:
    client_secret = read_secret(config.client_secret_file)
    pmxcfs.wait_writable(config.pmxcfs_directory, "configuring OIDC", stderr)

    common = (
        "--issuer-url",
        config.issuer_url,
        "--client-id",
        config.client_id,
        "--client-key",
        client_secret,
        "--autocreate",
        binary(config.autocreate_users),
        "--groups-claim",
        config.groups_claim,
        "--groups-autocreate",
        binary(config.autocreate_groups),
        "--groups-overwrite",
        binary(config.overwrite_groups),
        "--scopes",
        " ".join(config.scopes),
        "--comment",
        config.comment,
    )
    if config.realm in pveum.listed("realm"):
        pveum.run("realm", "modify", config.realm, *common)
    else:
        pveum.run(
            "realm",
            "add",
            config.realm,
            "--type",
            "openid",
            "--username-claim",
            config.username_claim,
            *common,
        )

    if config.mapped_group not in pveum.listed("group"):
        pveum.run(
            "group",
            "add",
            config.mapped_group,
            "--comment",
            config.group_comment,
        )
    pveum.run(
        "aclmod",
        config.acl_path,
        "-groups",
        config.mapped_group,
        "-roles",
        config.role,
    )


def load_config(path: Path) -> OidcConfig:
    try:
        return OidcConfig.model_validate_json(path.read_text())
    except (OSError, ValidationError, ValueError) as error:
        raise Error(f"failed to load Proxmox OIDC configuration from {path}") from error


def parser() -> argparse.ArgumentParser:
    argument_parser = argparse.ArgumentParser(description="Configure the Proxmox VE OIDC realm")
    argument_parser.add_argument("--config", type=Path, required=True)
    return argument_parser


def run(arguments: Sequence[str], stderr: TextIO) -> int:
    options = parser().parse_args(arguments)
    try:
        config = load_config(options.config)
        configure_oidc(
            config,
            PveumClient(SubprocessRunner(), (str(config.pveum),)),
            Pmxcfs(),
            stderr,
        )
    except Error as error:
        print(f"proxmox-configure-oidc: {error}", file=stderr)
        return 1
    return 0


def main() -> None:
    raise SystemExit(run(sys.argv[1:], sys.stderr))
