from pathlib import Path

from _pytest.capture import CaptureFixture

from hba_flash.cli import defaults, main, options, parser
from hba_flash.models import BundleDefaults, FlashOptions


def test_parser_preserves_operator_options() -> None:
    namespace = parser().parse_args(
        [
            "--host",
            "storage",
            "--controller",
            "2",
            "--firmware",
            "firmware.bin",
            "--flash",
            "--no-quiesce",
            "--reboot",
            "--keep-remote",
        ]
    )

    assert options(namespace) == FlashOptions(
        host="storage",
        controller="2",
        firmware=Path("firmware.bin"),
        flash=True,
        quiesce=False,
        reboot=True,
        keep_remote=True,
    )


def test_default_bundles_come_from_package_environment() -> None:
    assert defaults(
        {
            "HBA_FLASH_DEFAULT_SAS3FLASH_BUNDLE": "/sas",
            "HBA_FLASH_DEFAULT_FIRMWARE_BUNDLE": "/firmware",
        }
    ) == BundleDefaults(Path("/sas"), Path("/firmware"))


def test_main_reports_operator_error_for_missing_input(
    tmp_path: Path,
    capsys: CaptureFixture[str],
) -> None:
    missing = tmp_path / "missing"

    assert main(["--sas3flash", str(missing), "--firmware", str(missing)]) == 1

    assert "[hba-flash] error: file not found:" in capsys.readouterr().err
