from pathlib import Path

from home_assistant_tools.cli import authentication, parser
from home_assistant_tools.models import AuthenticationConfig


def test_cli_parses_shared_authentication_and_backup_retention() -> None:
    namespace = parser().parse_args(
        [
            "backup",
            "--base-url",
            "http://home",
            "--client-id",
            "client",
            "--owner-username",
            "owner",
            "--password-file",
            "/run/password",
            "--keep-backups",
            "5",
        ]
    )

    assert authentication(namespace) == AuthenticationConfig(
        "http://home",
        "client",
        "owner",
        Path("/run/password"),
    )
    assert namespace.keep_backups == 5
