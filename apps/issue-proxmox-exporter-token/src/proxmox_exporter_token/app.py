from __future__ import annotations

import argparse
import os
import platform
import socket
from collections.abc import Sequence
from pathlib import Path

from sops_tools.errors import ToolError
from sops_tools.process import SubprocessRunner
from sops_tools.repository import RuntimeEnvironment

from .repository import (
    NixEvaluator,
    configured_hosts_path,
    discover_repo_root,
    load_fleet_hosts,
)
from .service import (
    RemoteTokenIssuer,
    SopsTokenStore,
    TokenRequest,
    TokenService,
)


DEFAULT_API_USER = "prometheus@pve"
DEFAULT_TOKEN_NAME = "metrics"
DEFAULT_ROLE = "PVEAuditor"
DEFAULT_ACL_PATH = "/"


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=("Issue the Proxmox VE exporter API token and store it in host SOPS secrets.")
    )
    parser.add_argument(
        "--issuer-host",
        help="Proxmox node used to issue the token.",
    )
    parser.add_argument(
        "--secret-host",
        action="append",
        dest="secret_hosts",
        help="Host secret to update; repeat to override enabled lab nodes.",
    )
    parser.add_argument("--user", default=DEFAULT_API_USER)
    parser.add_argument("--token-name", default=DEFAULT_TOKEN_NAME)
    parser.add_argument("--role", default=DEFAULT_ROLE)
    parser.add_argument("--path", default=DEFAULT_ACL_PATH)
    parser.add_argument("--replace", action="store_true")
    token = parser.add_mutually_exclusive_group()
    token.add_argument(
        "--token-value",
        help="Store an existing token without issuing one remotely.",
    )
    token.add_argument(
        "--token-value-file",
        type=Path,
        help="Read an existing token from a file.",
    )
    parser.add_argument(
        "--comment",
        default="Prometheus PVE exporter metrics user",
    )
    return parser


def run(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    runner = SubprocessRunner()
    environment = dict(os.environ)
    root = discover_repo_root(
        Path.cwd(),
        environment.get("PKI_TOOLS_REPO_ROOT"),
    )
    hosts = load_fleet_hosts(configured_hosts_path(environment))
    runtime = RuntimeEnvironment(
        repo_root=root,
        home=Path.home(),
        config_home=Path(environment.get("XDG_CONFIG_HOME", str(Path.home() / ".config"))),
        system_name=platform.system(),
        hostname=socket.gethostname(),
        values=environment,
    )
    token_value = str(args.token_value) if args.token_value is not None else None
    if args.token_value_file is not None:
        token_value = args.token_value_file.read_text().strip()
    if token_value == "":
        raise ToolError("token value must not be empty")

    summary = TokenService(
        hosts=hosts,
        evaluator=NixEvaluator(runner, root),
        issuer=RemoteTokenIssuer(runner, root),
        store=SopsTokenStore(runtime, hosts),
    ).run(
        requested_hosts=args.secret_hosts,
        issuer_host=args.issuer_host,
        request=TokenRequest(
            user=str(args.user),
            token_name=str(args.token_name),
            role=str(args.role),
            acl_path=str(args.path),
            replace=bool(args.replace),
            comment=str(args.comment),
        ),
        token_value=token_value,
    )
    print(summary.model_dump_json())
    return 0


def main() -> int:
    try:
        return run()
    except (OSError, ToolError) as error:
        raise SystemExit(str(error)) from error
