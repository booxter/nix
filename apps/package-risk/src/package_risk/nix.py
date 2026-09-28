from __future__ import annotations

import json
import os
import re
import tempfile
from collections.abc import Callable, Iterable
from pathlib import Path

from pydantic import TypeAdapter, ValidationError

from .models import (
    Component,
    ComponentRequest,
    Configuration,
    DerivationRecord,
    ExternalComparison,
    MetadataRequest,
    MetadataResponse,
    PathInfo,
    VulnixRecord,
    json_object,
)
from .process import CommandRunner, RiskError

CONFIGURATIONS = TypeAdapter(list[Configuration])
PATH_INFO = TypeAdapter(dict[str, PathInfo])
DERIVATIONS = TypeAdapter(dict[str, DerivationRecord])
VULNIX_RECORDS = TypeAdapter(list[VulnixRecord])


def parse_store_name(path: str) -> tuple[str, str, str]:
    store_name = Path(path).name.partition("-")[2]
    match = re.match(r"(.+?)-([0-9].*)$", store_name)
    if match:
        return store_name, match.group(1), match.group(2)
    return store_name, store_name, ""


def flake_for_eval(reference: str) -> str:
    path = Path(reference)
    if path.exists():
        return f"path:{path.resolve()}"
    return reference


def candidate_paths(component: Component) -> list[list[str]]:
    names = list(
        dict.fromkeys((component.pname, component.pname.lower(), component.pname.replace("-", "_")))
    )
    sets: list[str] = []
    python = re.match(r"python(\d+)\.(\d+)-", component.name)
    lua = re.match(r"lua(\d+)\.(\d+)-", component.name)
    if python:
        sets.extend((f"python{python.group(1)}{python.group(2)}Packages", "python3Packages"))
    elif re.match(r"perl\d+(?:\.\d+)+-", component.name):
        sets.append("perlPackages")
    elif re.match(r"ruby\d+(?:\.\d+)+-", component.name):
        sets.append("rubyPackages")
    elif lua:
        sets.extend((f"lua{lua.group(1)}{lua.group(2)}Packages", "luaPackages"))
    elif component.name.startswith("vimplugin-"):
        sets.append("vimPlugins")
    elif component.name.startswith("emacs-"):
        sets.append("emacsPackages")
    paths = [[name] for name in names]
    paths.extend([[package_set, name] for package_set in sets for name in names])
    unique: list[list[str]] = []
    seen: set[tuple[str, ...]] = set()
    for path in paths:
        key = tuple(path)
        if key not in seen:
            seen.add(key)
            unique.append(path)
    return unique


class NixClient:
    def __init__(
        self,
        runner: CommandRunner,
        *,
        inventory_helper: Path,
        metadata_helper: Path,
        vulnix: Path,
        store_path_exists: Callable[[str], bool] = os.path.exists,
    ) -> None:
        self.runner = runner
        self.inventory_helper = inventory_helper
        self.metadata_helper = metadata_helper
        self.vulnix = vulnix
        self.store_path_exists = store_path_exists

    def inventory(self, flake: str) -> list[Configuration]:
        output = self.runner.run(
            (
                "nix",
                "eval",
                "--impure",
                "--json",
                "--file",
                str(self.inventory_helper),
            ),
            environment={"PACKAGE_RISK_FLAKE_REF": flake_for_eval(flake)},
        ).stdout
        try:
            return CONFIGURATIONS.validate_json(output)
        except ValidationError as error:
            raise RiskError(f"could not parse configuration inventory: {error}") from error

    @staticmethod
    def target(flake: str, configuration: Configuration) -> str:
        output = "nixosConfigurations" if configuration.kind == "nixos" else "darwinConfigurations"
        return f"{flake}#{output}.{configuration.name}.config.system.build.toplevel"

    def realize(self, target: str, *, build: bool) -> tuple[str, ...]:
        arguments: tuple[str, ...]
        if build:
            arguments = ("nix", "build", "--no-link", "--print-out-paths", target)
        else:
            arguments = ("nix", "eval", "--raw", f"{target}.outPath")
        result = self.runner.run(arguments).stdout
        paths = tuple(line for line in result.splitlines() if line.startswith("/nix/store/"))
        if not paths:
            raise RiskError(f"Nix returned no output paths for {target}")
        return paths

    def closure(self, outputs: Iterable[str]) -> tuple[int, list[Component]]:
        path_output = self.runner.run(
            (
                "nix",
                "path-info",
                "--json",
                "--json-format",
                "1",
                "--recursive",
                *outputs,
            )
        ).stdout
        try:
            paths = PATH_INFO.validate_json(path_output)
        except ValidationError as error:
            raise RiskError(f"could not parse runtime closure: {error}") from error
        outputs_by_deriver: dict[str, list[str]] = {}
        orphan_outputs: list[str] = []
        for output, entry in paths.items():
            if entry.deriver:
                outputs_by_deriver.setdefault(entry.deriver, []).append(output)
            else:
                orphan_outputs.append(output)
        derivers = sorted(outputs_by_deriver)
        present_derivers = [path for path in derivers if self.store_path_exists(path)]
        components = []
        if present_derivers:
            derivation_output = self.runner.run(
                ("nix", "derivation", "show", "--stdin"),
                stdin="\n".join(present_derivers),
            ).stdout
            components.extend(
                self._components(derivation_output, present_derivers, outputs_by_deriver)
            )
        present = {component.drv_path for component in components}
        for deriver in derivers:
            if deriver in present:
                continue
            output = min(outputs_by_deriver[deriver], key=len)
            name, pname, version = parse_store_name(output)
            components.append(Component(deriver, output, name, pname, version))
        for output in orphan_outputs:
            name, pname, version = parse_store_name(output)
            if version:
                components.append(Component("", output, name, pname, version))
        components.sort(key=lambda item: (item.pname.lower(), item.version, item.drv_path))
        return len(paths), components

    @staticmethod
    def _components(
        output: str,
        requested_paths: list[str],
        outputs_by_deriver: dict[str, list[str]] | None = None,
    ) -> list[Component]:
        try:
            document = json_object(json.loads(output))
            raw_derivations = document.get("derivations", document)
            derivations = DERIVATIONS.validate_python(raw_derivations)
        except (ValueError, json.JSONDecodeError, ValidationError) as error:
            raise RiskError(f"could not parse derivations: {error}") from error
        requested_by_name = {Path(path).name: path for path in requested_paths}
        components: list[Component] = []
        for key, record in derivations.items():
            environment = record.env
            pname = environment.get("pname", "")
            version = environment.get("version", "")
            name = environment.get("name", "")
            if not pname or not version or not name:
                continue
            full_path = (
                key
                if key.startswith("/nix/store/")
                else requested_by_name.get(key, f"/nix/store/{key}")
            )
            output_path = min((outputs_by_deriver or {}).get(full_path, [""]), key=len)
            components.append(Component(full_path, output_path, name, pname, version))
        return sorted(
            components, key=lambda item: (item.pname.lower(), item.version, item.drv_path)
        )

    def metadata(
        self,
        *,
        flake: str,
        configuration: Configuration,
        components: Iterable[Component],
        comparison_inputs: list[str],
        external_comparisons: list[ExternalComparison],
    ) -> MetadataResponse:
        request = MetadataRequest(
            flakeRef=flake_for_eval(flake),
            kind=configuration.kind,
            config=configuration.name,
            system=configuration.system,
            comparisonInputs=comparison_inputs,
            externalComparisons=external_comparisons,
            components=[
                ComponentRequest(
                    drvPath=component.drv_path,
                    outputPath=component.output_path,
                    name=component.name,
                    pname=component.pname,
                    version=component.version,
                    candidatePaths=candidate_paths(component),
                )
                for component in components
            ],
        )
        with tempfile.NamedTemporaryFile(mode="w", suffix=".json") as request_file:
            request_file.write(request.model_dump_json())
            request_file.flush()
            output = self.runner.run(
                (
                    "nix",
                    "eval",
                    "--impure",
                    "--json",
                    "--file",
                    str(self.metadata_helper),
                ),
                environment={"PACKAGE_RISK_REQUEST_PATH": request_file.name},
            ).stdout
        try:
            return MetadataResponse.model_validate_json(output)
        except ValidationError as error:
            raise RiskError(f"could not parse package metadata: {error}") from error

    def vulnerabilities(self, outputs: Iterable[str]) -> list[VulnixRecord]:
        result = self.runner.run(
            (str(self.vulnix), "--json", "--closure", *outputs),
            accepted_codes=(0, 2),
        )
        try:
            return VULNIX_RECORDS.validate_json(result.stdout)
        except ValidationError as error:
            raise RiskError(f"could not parse vulnix results: {error}") from error
