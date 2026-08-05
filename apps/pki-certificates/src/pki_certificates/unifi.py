from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path, PurePath

from atomic_file_writes import write_text_atomic
from sops_tools.errors import ToolError

from .issuer import CertificateIssuer
from .models import UnifiDefaults, UnifiResult
from .services import unique_strings


def validate_basename(value: str) -> str:
    basename = PurePath(value)
    if basename.name != value or value in ("", ".", ".."):
        raise ToolError(f"invalid output basename: {value}")
    return value


def write_output(path: Path, text: str, mode: int, *, force: bool) -> None:
    if path.exists() and not force:
        raise ToolError(f"refusing to overwrite existing file: {path}")
    write_text_atomic(path, text, mode=mode)


@dataclass(frozen=True)
class UnifiCertificateService:
    issuer: CertificateIssuer
    defaults: UnifiDefaults

    def issue(
        self,
        *,
        ca_host: str,
        output_dir: Path,
        common_name: str | None,
        additional_sans: list[str],
        include_gateway_ip: bool,
        basename: str | None,
        force: bool,
    ) -> UnifiResult:
        name = common_name or self.defaults.common_name
        values = [name, *self.defaults.sans, *additional_sans]
        if include_gateway_ip:
            values.append(self.defaults.gateway_ip)
        sans = unique_strings(values)
        output_name = validate_basename(basename or name)
        directory = output_dir.expanduser().resolve()
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)

        certificate_path = directory / f"{output_name}.crt"
        private_key_path = directory / f"{output_name}.key"
        pem_path = directory / f"{output_name}.pem"
        material = self.issuer.issue(ca_host, name, sans)
        write_output(certificate_path, material.certificate_pem, 0o644, force=force)
        write_output(private_key_path, material.private_key_pem, 0o600, force=force)
        write_output(
            pem_path,
            material.certificate_pem + "\n" + material.private_key_pem,
            0o600,
            force=force,
        )
        return UnifiResult(
            ca_host=ca_host,
            common_name=name,
            sans=sans,
            cert_file=str(certificate_path),
            key_file=str(private_key_path),
            pem_file=str(pem_path),
        )
