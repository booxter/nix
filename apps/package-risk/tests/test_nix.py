from __future__ import annotations

import json
from pathlib import Path

import pytest
from package_risk.models import Component, Configuration, ExternalComparison
from package_risk.nix import NixClient, candidate_paths, flake_for_eval, parse_store_name
from package_risk.process import RiskError

from .fakes import FakeRunner, result


def client(runner: FakeRunner) -> NixClient:
    return NixClient(
        runner,
        inventory_helper=Path("/helpers/inventory.nix"),
        metadata_helper=Path("/helpers/metadata.nix"),
        vulnix=Path("/tools/vulnix"),
        store_path_exists=lambda _path: True,
    )


def test_flake_for_eval_resolves_paths(tmp_path: Path) -> None:
    assert flake_for_eval(str(tmp_path)) == f"path:{tmp_path.resolve()}"
    assert flake_for_eval("github:owner/repo") == "github:owner/repo"


def test_parse_store_name() -> None:
    assert parse_store_name("/nix/store/hash-openssl-3.5.2") == (
        "openssl-3.5.2",
        "openssl",
        "3.5.2",
    )
    assert parse_store_name("/nix/store/hash-config") == ("config", "config", "")


@pytest.mark.parametrize(
    ("name", "expected_set"),
    [
        ("python3.13-requests-1", "python313Packages"),
        ("perl5.40.0-Foo-1", "perlPackages"),
        ("ruby3.4-foo-1", "rubyPackages"),
        ("lua5.4-foo-1", "lua54Packages"),
        ("vimplugin-foo", "vimPlugins"),
        ("emacs-foo", "emacsPackages"),
    ],
)
def test_candidate_paths_include_language_package_set(name: str, expected_set: str) -> None:
    paths = candidate_paths(Component("/nix/store/x.drv", "/nix/store/x", name, "Foo-Bar", "1"))
    assert ["Foo-Bar"] in paths
    assert ["foo-bar"] in paths
    assert [expected_set, "Foo-Bar"] in paths
    assert len(paths) == len({tuple(path) for path in paths})


def test_inventory_and_targets() -> None:
    runner = FakeRunner([result('[{"kind":"nixos","name":"host","system":"x86_64-linux"}]')])
    nix = client(runner)
    inventory = nix.inventory("github:owner/repo")
    assert inventory[0].name == "host"
    assert runner.calls[0].environment == {"PACKAGE_RISK_FLAKE_REF": "github:owner/repo"}
    assert (
        nix.target(".", inventory[0]) == ".#nixosConfigurations.host.config.system.build.toplevel"
    )
    darwin = Configuration(kind="darwin", name="mac", system="aarch64-darwin")
    assert nix.target(".", darwin) == ".#darwinConfigurations.mac.config.system.build.toplevel"


def test_invalid_inventory_is_reported() -> None:
    with pytest.raises(RiskError, match="configuration inventory"):
        client(FakeRunner([result("{}")])).inventory(".")


def test_realize_build_and_evaluation_only() -> None:
    runner = FakeRunner([result("/nix/store/one\n"), result("/nix/store/two\n")])
    nix = client(runner)
    assert nix.realize("target", build=True) == ("/nix/store/one",)
    assert runner.calls[0].arguments == (
        "nix",
        "build",
        "--no-link",
        "--print-out-paths",
        "target",
    )
    assert nix.realize("target", build=False) == ("/nix/store/two",)
    assert runner.calls[1].arguments == ("nix", "eval", "--raw", "target.outPath")


def test_realize_requires_an_output_path() -> None:
    with pytest.raises(RiskError, match="no output paths"):
        client(FakeRunner([result("warning only")])).realize("target", build=True)


def test_closure_parses_nix_235_derivations() -> None:
    path_info = json.dumps(
        {
            "/nix/store/out": {"deriver": "/nix/store/hash-hello-1.drv"},
            "/nix/store/hash-zlib-1": {"deriver": None},
        }
    )
    derivations = json.dumps(
        {
            "version": 4,
            "derivations": {
                "hash-hello-1.drv": {"env": {"name": "hello-1", "pname": "hello", "version": "1"}},
                "source.drv": {"env": {"name": "source"}},
            },
        }
    )
    runner = FakeRunner([result(path_info), result(derivations)])
    count, components = client(runner).closure(["/nix/store/out"])
    assert count == 2
    assert components == [
        Component(
            "/nix/store/hash-hello-1.drv",
            "/nix/store/out",
            "hello-1",
            "hello",
            "1",
        ),
        Component("", "/nix/store/hash-zlib-1", "zlib-1", "zlib", "1"),
    ]
    assert runner.calls[1].stdin == "/nix/store/hash-hello-1.drv"


def test_closure_handles_old_schema_and_empty_derivers() -> None:
    old = json.dumps(
        {"/nix/store/hash-zlib.drv": {"env": {"name": "zlib-1", "pname": "zlib", "version": "1"}}}
    )
    component = NixClient._components(old, ["/nix/store/hash-zlib.drv"])[0]
    assert component.pname == "zlib"
    assert client(FakeRunner([result('{"/nix/store/plain":{"deriver":null}}')])).closure(
        ["/nix/store/plain"]
    ) == (1, [])


def test_closure_falls_back_when_derivation_is_missing() -> None:
    path_info = json.dumps(
        {
            "/nix/store/hash-hello-2.0": {"deriver": "/nix/store/hash-hello-2.0.drv"},
            "/nix/store/hash-hello-2.0-dev": {"deriver": "/nix/store/hash-hello-2.0.drv"},
        }
    )
    runner = FakeRunner([result(path_info)])
    nix = NixClient(
        runner,
        inventory_helper=Path("/helpers/inventory.nix"),
        metadata_helper=Path("/helpers/metadata.nix"),
        vulnix=Path("/tools/vulnix"),
        store_path_exists=lambda _path: False,
    )
    assert nix.closure(["/nix/store/system"]) == (
        2,
        [
            Component(
                "/nix/store/hash-hello-2.0.drv",
                "/nix/store/hash-hello-2.0",
                "hello-2.0",
                "hello",
                "2.0",
            )
        ],
    )
    assert len(runner.calls) == 1


def test_closure_uses_versioned_outputs_when_all_derivers_are_missing() -> None:
    path_info = json.dumps(
        {
            "/nix/store/hash-zlib-1.3.1": {"deriver": None},
            "/nix/store/hash-source": {"deriver": None},
        }
    )
    count, components = client(FakeRunner([result(path_info)])).closure(["/nix/store/system"])
    assert count == 2
    assert components == [
        Component("", "/nix/store/hash-zlib-1.3.1", "zlib-1.3.1", "zlib", "1.3.1")
    ]


@pytest.mark.parametrize("document", ["[]", "not-json"])
def test_invalid_derivations_are_reported(document: str) -> None:
    with pytest.raises(RiskError, match="could not parse derivations"):
        NixClient._components(document, [])


def test_invalid_closure_is_reported() -> None:
    with pytest.raises(RiskError, match="runtime closure"):
        client(FakeRunner([result("[]")])).closure([])


def test_metadata_serializes_request_and_parses_response(tmp_path: Path) -> None:
    response = json.dumps(
        {
            "components": [
                {
                    "drvPath": "/nix/store/x.drv",
                    "name": "hello-1",
                    "pname": "hello",
                    "version": "1",
                    "attrPath": ["hello"],
                    "meta": {
                        "maintainers": ["alice"],
                        "teams": [],
                        "knownVulnerabilities": [],
                        "position": "package.nix:1",
                    },
                    "comparisons": [
                        {"label": "unstable", "version": "2", "knownVulnerabilities": []}
                    ],
                }
            ]
        }
    )
    runner = FakeRunner([result(response)])
    configuration = Configuration(kind="nixos", name="host", system="x86_64-linux")
    metadata = client(runner).metadata(
        flake=str(tmp_path),
        configuration=configuration,
        components=[Component("/nix/store/x.drv", "/nix/store/x", "hello-1", "hello", "1")],
        comparison_inputs=["nixpkgs-unstable"],
        external_comparisons=[
            ExternalComparison(label="staging", flakeRef="github:NixOS/nixpkgs/staging")
        ],
    )
    assert metadata.components[0].meta.maintainers == ["alice"]
    request = runner.metadata_requests[0]
    assert request["flakeRef"] == f"path:{tmp_path.resolve()}"
    assert request["comparisonInputs"] == ["nixpkgs-unstable"]
    assert request["components"][0]["outputPath"] == "/nix/store/x"


def test_invalid_metadata_is_reported() -> None:
    with pytest.raises(RiskError, match="package metadata"):
        client(FakeRunner([result("[]")])).metadata(
            flake="github:owner/repo",
            configuration=Configuration(kind="nixos", name="host", system="x86_64-linux"),
            components=[],
            comparison_inputs=[],
            external_comparisons=[],
        )


def test_vulnerabilities_accept_finding_exit_code() -> None:
    payload = json.dumps(
        [
            {
                "name": "openssl-1",
                "pname": "openssl",
                "version": "1",
                "derivation": "/nix/store/o.drv",
                "affected_by": ["CVE-1"],
                "cvssv3_basescore": {"CVE-1": 9.8},
            }
        ]
    )
    runner = FakeRunner([result(payload, 2)])
    records = client(runner).vulnerabilities(["/nix/store/system"])
    assert records[0].affected_by == ["CVE-1"]
    assert runner.calls[0].accepted_codes == (0, 2)


def test_invalid_vulnerabilities_are_reported() -> None:
    with pytest.raises(RiskError, match="vulnix results"):
        client(FakeRunner([result("{}")])).vulnerabilities([])
