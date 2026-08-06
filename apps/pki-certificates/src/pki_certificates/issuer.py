from __future__ import annotations

import shlex
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol

from pydantic import ValidationError
from sops_tools.errors import ToolError
from sops_tools.flake import archive_flake_source
from sops_tools.process import ProcessRunner

from .models import (
    CertificateMaterial,
    CertificateRequest,
    FleetHosts,
)
from .repository import host_facts


class CertificateIssuer(Protocol):
    def issue(
        self, ca_host: str, common_name: str, sans: tuple[str, ...]
    ) -> CertificateMaterial: ...


@dataclass(frozen=True)
class StepCaIssuer:
    runner: ProcessRunner

    def issue(self, request: CertificateRequest) -> CertificateMaterial:
        with tempfile.TemporaryDirectory(prefix="pki-certificate-") as temporary:
            directory = Path(temporary)
            certificate = directory / "certificate.crt"
            private_key = directory / "certificate.key"
            arguments = [
                "step",
                "ca",
                "certificate",
                request.common_name,
                str(certificate),
                str(private_key),
            ]
            for san in request.sans:
                arguments.extend(["--san", san])
            arguments.extend(
                [
                    "--provisioner",
                    "bootstrap@home.arpa",
                    "--provisioner-password-file",
                    "/var/lib/step-ca/provisioner-password.txt",
                    "--ca-url",
                    request.ca_url,
                ]
            )
            self.runner.run(arguments)
            try:
                return CertificateMaterial(
                    certificate_pem=certificate.read_text().strip() + "\n",
                    private_key_pem=private_key.read_text().strip() + "\n",
                )
            except OSError as error:
                raise ToolError(
                    f"step did not produce readable certificate files: {error}"
                ) from error


@dataclass(frozen=True)
class RemoteCertificateIssuer:
    runner: ProcessRunner
    repo_root: Path
    hosts: FleetHosts
    local_ca: bool
    remote_program: Path

    def issue(self, ca_host: str, common_name: str, sans: tuple[str, ...]) -> CertificateMaterial:
        facts = host_facts(self.hosts, ca_host)
        if facts.ca_url is None:
            raise ToolError(f"host {ca_host} is not configured as a certificate authority")
        request = CertificateRequest(
            common_name=common_name,
            sans=sans,
            ca_url=facts.ca_url,
        )
        if self.local_ca:
            output = self.runner.run(
                ["sudo", "-n", "-H", "-u", "step-ca", str(self.remote_program)],
                input_text=request.model_dump_json(),
            )
        else:
            source = self._archive_source()
            self.runner.run(
                ["nix", "copy", "--to", f"ssh-ng://{ca_host}", str(source)],
                capture_output=False,
            )
            # OpenSSH has no remote argv protocol. This fixed command contains
            # no request data; the validated request travels over stdin.
            command = shlex.join(
                [
                    "sudo",
                    "-n",
                    "-H",
                    "-u",
                    "step-ca",
                    "nix",
                    "shell",
                    "-L",
                    "--show-trace",
                    f"path:{source}#pki-certificates",
                    "--command",
                    "pki-issue-certificate-remote",
                ]
            )
            output = self.runner.run(
                ["ssh", ca_host, command], input_text=request.model_dump_json()
            )
        try:
            return CertificateMaterial.model_validate_json(output)
        except ValidationError as error:
            raise ToolError(f"invalid certificate response from {ca_host}: {error}") from error

    def _archive_source(self) -> Path:
        return archive_flake_source(self.runner, self.repo_root)
