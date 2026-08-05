from __future__ import annotations

import io
import zipfile
from dataclasses import dataclass, field
from pathlib import Path

import pytest

from hba_flash.models import Artifacts, BundleDefaults, FlashOptions
from hba_flash.process import FlashError
from hba_flash.workflow import HbaFlashWorkflow


@dataclass
class SimulatedRemote:
    fail_verification: bool = False
    require_verification: bool = True
    host: str | None = None
    controller: str | None = None
    preflighted: bool = False
    staging_created: bool = False
    staged_sources: dict[str, Path] = field(default_factory=dict)
    tool_checked: bool = False
    quiesced: bool = False
    verified: bool = False
    flashed: bool = False
    flashed_optionrom: bool = False
    rebooted: bool = False
    cleaned: bool = False

    def preflight(self, controller: str) -> None:
        self.controller = controller
        self.preflighted = True

    def stage(self, _directory: str, artifacts: Artifacts) -> None:
        self.staging_created = True
        self.staged_sources = {
            "sas3flash": artifacts.sas3flash,
            "firmware.bin": artifacts.firmware,
        }
        if artifacts.optionrom is not None:
            self.staged_sources["optionrom.rom"] = artifacts.optionrom

    def check_tool(self, _directory: str, _controller: str) -> None:
        if not {"sas3flash", "firmware.bin"} <= self.staged_sources.keys():
            raise AssertionError("tool check ran before required artifacts were staged")
        self.tool_checked = True

    def quiesce(self) -> None:
        self.quiesced = True

    def verify_quiesced(self) -> None:
        if not self.quiesced:
            raise AssertionError("quiesce verification ran before quiescing")
        if self.fail_verification:
            raise FlashError("host did not quiesce")
        self.verified = True

    def flash(self, _directory: str, _controller: str, with_optionrom: bool) -> None:
        if self.require_verification and not self.verified:
            raise AssertionError("flash ran without successful quiesce verification")
        self.flashed = True
        self.flashed_optionrom = with_optionrom

    def reboot(self) -> None:
        self.rebooted = True

    def cleanup(self, _directory: str) -> None:
        self.cleaned = True


def inputs(tmp_path: Path) -> tuple[Path, Path]:
    utility = tmp_path / "sas3flash"
    firmware = tmp_path / "firmware.bin"
    utility.touch()
    firmware.touch()
    return utility, firmware


def workflow(remote: SimulatedRemote) -> HbaFlashWorkflow:
    return HbaFlashWorkflow(
        lambda host: _assign_host(remote, host), io.StringIO(), lambda: "/tmp/hba-flash-fixed"
    )


def _assign_host(remote: SimulatedRemote, host: str) -> SimulatedRemote:
    remote.host = host
    return remote


def test_preflight_is_read_only_and_cleans_staging(tmp_path: Path) -> None:
    utility, firmware = inputs(tmp_path)
    remote = SimulatedRemote()

    workflow(remote).execute(
        FlashOptions(
            host="storage",
            controller="2",
            sas3flash=utility,
            firmware=firmware,
        ),
        BundleDefaults(),
    )

    assert remote.host == "storage"
    assert remote.controller == "2"
    assert remote.preflighted
    assert remote.staging_created
    assert set(remote.staged_sources) == {"sas3flash", "firmware.bin"}
    assert remote.tool_checked
    assert not remote.quiesced
    assert not remote.flashed
    assert remote.cleaned


def test_flash_quiesces_and_verifies_before_flashing(tmp_path: Path) -> None:
    utility, firmware = inputs(tmp_path)
    optionrom = tmp_path / "optionrom.rom"
    optionrom.touch()
    remote = SimulatedRemote()

    workflow(remote).execute(
        FlashOptions(
            sas3flash=utility,
            firmware=firmware,
            optionrom=optionrom,
            flash=True,
            reboot=True,
        ),
        BundleDefaults(),
    )

    assert set(remote.staged_sources) == {
        "sas3flash",
        "firmware.bin",
        "optionrom.rom",
    }
    assert remote.quiesced
    assert remote.verified
    assert remote.flashed
    assert remote.flashed_optionrom
    assert remote.rebooted
    assert remote.cleaned


def test_failed_quiesce_verification_blocks_flash_and_cleans(tmp_path: Path) -> None:
    utility, firmware = inputs(tmp_path)
    remote = SimulatedRemote(fail_verification=True)

    with pytest.raises(FlashError, match="host did not quiesce"):
        workflow(remote).execute(
            FlashOptions(sas3flash=utility, firmware=firmware, flash=True),
            BundleDefaults(),
        )

    assert remote.quiesced
    assert not remote.verified
    assert not remote.flashed
    assert remote.cleaned


def test_zip_bundle_selects_preferred_artifacts_and_removes_extraction(
    tmp_path: Path,
) -> None:
    archive = tmp_path / "bundle.zip"
    with zipfile.ZipFile(archive, "w") as bundle:
        bundle.writestr("tools/sas3flash_linux_x64_rel/sas3flash", "binary")
        bundle.writestr("firmware/SAS9305_24i_IT_P.bin", "firmware")
    remote = SimulatedRemote()

    workflow(remote).execute(FlashOptions(bundle=archive), BundleDefaults())

    utility = remote.staged_sources["sas3flash"]
    firmware = remote.staged_sources["firmware.bin"]
    assert utility.as_posix().endswith("/tools/sas3flash_linux_x64_rel/sas3flash")
    assert firmware.as_posix().endswith("/firmware/SAS9305_24i_IT_P.bin")
    assert not utility.exists()
    assert not firmware.exists()


def test_explicit_unsafe_mode_skips_quiesce_and_keeps_staging(tmp_path: Path) -> None:
    utility, firmware = inputs(tmp_path)
    remote = SimulatedRemote(require_verification=False)
    stderr = io.StringIO()
    controller = HbaFlashWorkflow(
        lambda host: _assign_host(remote, host),
        stderr,
        lambda: "/tmp/hba-flash-fixed",
    )

    controller.execute(
        FlashOptions(
            sas3flash=utility,
            firmware=firmware,
            flash=True,
            quiesce=False,
            keep_remote=True,
        ),
        BundleDefaults(),
    )

    assert not remote.quiesced
    assert not remote.verified
    assert remote.flashed
    assert not remote.cleaned
    assert "flash completed; reboot beast" in stderr.getvalue()


def test_ambiguous_firmware_is_rejected_before_remote_access(tmp_path: Path) -> None:
    utility, _firmware = inputs(tmp_path)
    bundle = tmp_path / "firmware"
    bundle.mkdir()
    (bundle / "SAS9305_24i_IT_A.bin").touch()
    (bundle / "SAS9305_24i_IT_B.bin").touch()
    remote = SimulatedRemote()

    with pytest.raises(FlashError, match="please pass --firmware explicitly"):
        workflow(remote).execute(
            FlashOptions(sas3flash=utility, firmware_bundle=bundle),
            BundleDefaults(),
        )

    assert not remote.preflighted
    assert remote.staged_sources == {}
