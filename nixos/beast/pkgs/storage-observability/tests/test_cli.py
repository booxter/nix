from pathlib import Path

from beast_storage_observability.cli import hba_parser, md_parser


def test_hba_cli_accepts_only_runtime_configuration() -> None:
    arguments = hba_parser().parse_args(
        ["--bay-map", "/etc/bays.json", "--output-file", "/var/lib/node/hba.prom"]
    )

    assert arguments.bay_map == Path("/etc/bays.json")
    assert arguments.output_file == Path("/var/lib/node/hba.prom")


def test_md_cli_exposes_only_the_output_path() -> None:
    arguments = md_parser().parse_args(["--output-file", "/var/lib/node/md.prom"])

    assert arguments.output_file == Path("/var/lib/node/md.prom")
