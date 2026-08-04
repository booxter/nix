from pathlib import Path

from beast_storage_observability.cli import hba_parser


def test_hba_cli_accepts_only_runtime_configuration() -> None:
    arguments = hba_parser().parse_args(
        ["--bay-map", "/etc/bays.json", "--output-file", "/var/lib/node/hba.prom"]
    )

    assert arguments.bay_map == Path("/etc/bays.json")
    assert arguments.output_file == Path("/var/lib/node/hba.prom")
