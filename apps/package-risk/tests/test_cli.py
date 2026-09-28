from __future__ import annotations

import json

import pytest
from package_risk.cli import _exit_code, run, select_configurations
from package_risk.models import Configuration
from package_risk.process import RiskError

from .fakes import FakeRunner, result

INVENTORY = [
    Configuration(kind="nixos", name="server", system="x86_64-linux"),
    Configuration(kind="darwin", name="mac", system="aarch64-darwin"),
]


def test_select_configurations() -> None:
    assert select_configurations(INVENTORY, ["mac"], False) == [INVENTORY[1]]
    assert select_configurations(INVENTORY, [], True) == INVENTORY
    with pytest.raises(RiskError, match="at least one"):
        select_configurations(INVENTORY, [], False)
    with pytest.raises(RiskError, match="not both"):
        select_configurations(INVENTORY, ["mac"], True)
    with pytest.raises(RiskError, match="not found"):
        select_configurations(INVENTORY, ["missing"], False)
    duplicate = [
        *INVENTORY,
        Configuration(kind="nixos", name="mac", system="x86_64-linux"),
    ]
    with pytest.raises(RiskError, match="ambiguous"):
        select_configurations(duplicate, ["mac"], False)


def test_run_reports_a_configuration(capsys: pytest.CaptureFixture[str]) -> None:
    inventory = json.dumps([item.model_dump() for item in INVENTORY])
    path_info = json.dumps({"/nix/store/system": {"deriver": "/nix/store/system.drv"}})
    metadata = json.dumps({"components": []})
    runner = FakeRunner(
        [
            result(inventory),
            result("/nix/store/system\n"),
            result(path_info),
            result(metadata),
        ]
    )
    status = run(
        ["server", "--no-tracker", "--staging", "--hyperlinks", "always"],
        runner=runner,
        environ={
            "PACKAGE_RISK_INVENTORY_NIX": "/inventory.nix",
            "PACKAGE_RISK_METADATA_NIX": "/metadata.nix",
            "PACKAGE_RISK_VULNIX": "/vulnix",
        },
    )
    captured = capsys.readouterr()
    assert status == 0
    assert "Package risk: server" in captured.out
    assert "server: realizing runtime closure" in captured.err
    assert runner.metadata_requests[0]["externalComparisons"] == [
        {"label": "staging", "flakeRef": "github:NixOS/nixpkgs/staging"}
    ]


def test_run_requires_wrapper_environment() -> None:
    with pytest.raises(RiskError, match="PACKAGE_RISK_INVENTORY_NIX"):
        run(["server"], runner=FakeRunner([]), environ={})


def test_exit_codes() -> None:
    from package_risk.audit import make_report
    from package_risk.models import MetadataRecord, PackageMeta, TrackerFinding, TrackerScan

    configuration = INVENTORY[0]
    clean = make_report(
        configuration,
        0,
        [],
        [],
        TrackerScan(findings=(), checked_packages=0, unclassified_matches=0),
    )
    unmaintained = make_report(
        configuration,
        1,
        [],
        [
            MetadataRecord(
                drvPath="x",
                name="x-1",
                pname="x",
                version="1",
                attrPath=["x"],
                meta=PackageMeta(maintainers=[], teams=[], knownVulnerabilities=[], position=""),
                comparisons=[],
            )
        ],
        TrackerScan(findings=(), checked_packages=0, unclassified_matches=0),
    )
    vulnerable = make_report(
        configuration,
        1,
        [],
        [
            MetadataRecord(
                drvPath="x",
                name="x-1",
                pname="x",
                version="1",
                attrPath=["x"],
                meta=PackageMeta(
                    maintainers=["alice"],
                    teams=[],
                    knownVulnerabilities=[],
                    position="",
                ),
                comparisons=[],
            )
        ],
        TrackerScan(
            findings=(
                TrackerFinding(
                    attr_path="x",
                    identifier="CVE-1",
                    score=None,
                    reference_url="https://tracker.example/CVE-1",
                ),
            ),
            checked_packages=1,
            unclassified_matches=0,
        ),
    )
    assert _exit_code([clean]) == 0
    assert _exit_code([unmaintained]) == 1
    assert _exit_code([vulnerable]) == 2
