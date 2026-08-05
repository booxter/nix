from __future__ import annotations

import argparse
import os
import platform
import shutil
import socket
from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path

from pydantic import ValidationError
from sops_tools.errors import ToolError
from sops_tools.process import SubprocessRunner
from sops_tools.repository import RuntimeEnvironment

from .issuer import RemoteCertificateIssuer
from .models import UnifiDefaults
from .repository import (
    NixConfigSource,
    configured_file,
    discover_repo_root,
    load_fleet_hosts,
)
from .secrets import SopsCertificateStore
from .services import ManagedCertificateService
from .unifi import UnifiCertificateService


DEFAULT_CA_HOST = "pki"


@dataclass(frozen=True)
class Application:
    managed: ManagedCertificateService
    unifi: UnifiCertificateService

    @classmethod
    def discover(cls) -> Application:
        environment = dict(os.environ)
        root = discover_repo_root(Path.cwd(), environment.get("PKI_TOOLS_REPO_ROOT"))
        hosts = load_fleet_hosts(configured_file(environment, "PKI_CERTIFICATE_HOSTS_FILE"))
        query = configured_file(environment, "PKI_CERTIFICATE_QUERY_FILE")
        defaults_path = configured_file(environment, "PKI_UNIFI_DEFAULTS_FILE")
        try:
            defaults = UnifiDefaults.model_validate_json(defaults_path.read_bytes())
        except (OSError, ValidationError) as error:
            raise ToolError(
                f"invalid UniFi certificate defaults {defaults_path}: {error}"
            ) from error
        remote_program_name = shutil.which("pki-issue-certificate-remote")
        if remote_program_name is None:
            raise ToolError("pki-issue-certificate-remote is not available on PATH")
        runner = SubprocessRunner()
        issuer = RemoteCertificateIssuer(
            runner=runner,
            repo_root=root,
            hosts=hosts,
            local_ca=environment.get("ISSUE_CERT_LOCAL_CA") == "1",
            remote_program=Path(remote_program_name),
        )
        home = Path(environment.get("HOME", str(Path.home())))
        runtime = RuntimeEnvironment(
            repo_root=root,
            home=home,
            config_home=Path(environment.get("XDG_CONFIG_HOME", str(home / ".config"))),
            system_name=platform.system(),
            hostname=socket.gethostname().split(".", maxsplit=1)[0],
            values=environment,
        )
        managed = ManagedCertificateService(
            NixConfigSource(runner, root, hosts, query),
            issuer,
            SopsCertificateStore(runtime, hosts),
        )
        return cls(managed, UnifiCertificateService(issuer, defaults))


def internal_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Issue internal PKI certificates for HTTPS services, mTLS clients, "
            "or UniFi import files."
        )
    )
    parser.add_argument("--host", help="inventory host name")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--service", help="internal HTTPS service name")
    mode.add_argument("--client", help="internal HTTPS mTLS client identity")
    mode.add_argument("--unifi", action="store_true", help="write UniFi import files")
    parser.add_argument("--output-dir", type=Path, help="UniFi output directory")
    parser.add_argument("--common-name", help="UniFi certificate common name")
    parser.add_argument("--san", action="append", default=[], help="additional UniFi SAN")
    parser.add_argument(
        "--include-gateway-ip",
        action="store_true",
        help="include the inventory gateway IP in the UniFi certificate",
    )
    parser.add_argument("--basename", help="UniFi output filename basename")
    parser.add_argument("--force", action="store_true", help="overwrite UniFi output files")
    parser.add_argument("--ca-host", default=DEFAULT_CA_HOST, help="host running step-ca")
    return parser


def observability_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Issue observability endpoint and client mTLS certificates."
    )
    parser.add_argument("--host", required=True, help="inventory host name")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--endpoint", help="Prometheus mTLS endpoint name")
    mode.add_argument("--client", help="observability mTLS client identity")
    parser.add_argument("--ca-host", default=DEFAULT_CA_HOST, help="host running step-ca")
    return parser


def run_internal(
    argv: Sequence[str] | None = None, *, application: Application | None = None
) -> int:
    parser = internal_parser()
    arguments = parser.parse_args(argv)
    current = application or Application.discover()
    if arguments.unifi:
        if arguments.host is not None:
            parser.error("--unifi cannot be combined with --host")
        if arguments.output_dir is None:
            parser.error("--output-dir is required with --unifi")
        unifi_result = current.unifi.issue(
            ca_host=str(arguments.ca_host),
            output_dir=arguments.output_dir,
            common_name=arguments.common_name,
            additional_sans=[str(value) for value in arguments.san],
            include_gateway_ip=bool(arguments.include_gateway_ip),
            basename=arguments.basename,
            force=bool(arguments.force),
        )
        print(unifi_result.model_dump_json())
        return 0

    unifi_options = (
        arguments.output_dir is not None
        or arguments.common_name is not None
        or bool(arguments.san)
        or arguments.include_gateway_ip
        or arguments.basename is not None
        or arguments.force
    )
    if unifi_options:
        parser.error("UniFi output options require --unifi")
    if arguments.host is None:
        parser.error("--host is required unless --unifi is used")
    host = str(arguments.host)
    ca_host = str(arguments.ca_host)
    if arguments.client is not None:
        results = [current.managed.issue_internal_client(host, str(arguments.client), ca_host)]
    else:
        names = (
            [str(arguments.service)]
            if arguments.service is not None
            else current.managed.internal_service_names(host)
        )
        if not names:
            raise ToolError(f"host {host} has no configured internal HTTPS services")
        results = [current.managed.issue_internal_service(host, name, ca_host) for name in names]
    for managed_result in results:
        print(managed_result.model_dump_json())
    return 0


def run_observability(
    argv: Sequence[str] | None = None, *, application: Application | None = None
) -> int:
    arguments = observability_parser().parse_args(argv)
    current = application or Application.discover()
    host = str(arguments.host)
    ca_host = str(arguments.ca_host)
    if arguments.endpoint is not None:
        results = [
            current.managed.issue_observability_endpoint(host, str(arguments.endpoint), ca_host)
        ]
    elif arguments.client is not None:
        results = [current.managed.issue_observability_client(host, str(arguments.client), ca_host)]
    else:
        endpoints = current.managed.observability_endpoint_names(host)
        clients = current.managed.observability_client_names(host)
        if not endpoints and not clients:
            raise ToolError(
                f"host {host} has no configured observability mTLS endpoints or clients"
            )
        results = [
            current.managed.issue_observability_endpoint(host, name, ca_host) for name in endpoints
        ]
        results.extend(
            current.managed.issue_observability_client(host, name, ca_host) for name in clients
        )
    for result in results:
        print(result.model_dump_json())
    return 0


def internal_main() -> int:
    try:
        return run_internal()
    except (OSError, ToolError) as error:
        raise SystemExit(str(error)) from error


def observability_main() -> int:
    try:
        return run_observability()
    except (OSError, ToolError) as error:
        raise SystemExit(str(error)) from error
