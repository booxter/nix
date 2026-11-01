from __future__ import annotations

from dataclasses import dataclass
from typing import Protocol

from proxmox_bootstrap.identity import IdentityError, validate_identity
from pydantic import BaseModel, ConfigDict, Field


class ProxDeployError(RuntimeError):
    """An expected deployment setup or installation error."""


class VmSpec(BaseModel):
    model_config = ConfigDict(frozen=True, strict=True, extra="forbid")

    nodes: tuple[str, ...] = Field(min_length=1)
    public_key: str = Field(min_length=1)


@dataclass(frozen=True)
class DeployRequest:
    vm_type: str
    node: str

    @property
    def password_reference(self) -> str:
        return f"host/{self.node}/root"

    @property
    def identity_reference(self) -> str:
        return f"host/{self.vm_type}/ssh_host_ed25519_key"


@dataclass(frozen=True)
class ProxmoxCredentials:
    host: str
    user: str
    password: str
    verify_ssl: bool = False

    def as_nixmoxer_environment(self) -> dict[str, str]:
        return {
            "PROXMOX_HOST": f"{self.host}:8006",
            "PROXMOX_USER": f"{self.user}@pam",
            "PROXMOX_PASSWORD": self.password,
            "PROXMOX_VERIFY_SSL": "1" if self.verify_ssl else "0",
        }


class PasswordStore(Protocol):
    def read(self, reference: str) -> str: ...


class VmDeployer(Protocol):
    def deploy(self, request: DeployRequest, credentials: ProxmoxCredentials) -> int: ...


class GuestInstaller(Protocol):
    def prepare(self, request: DeployRequest) -> None: ...

    def install(self, request: DeployRequest, vmid: int, identity: bytes) -> None: ...


def deploy_vm(
    request: DeployRequest,
    spec: VmSpec,
    password_store: PasswordStore,
    deployer: VmDeployer,
    installer: GuestInstaller,
) -> int:
    identity = password_store.read(request.identity_reference).encode()
    try:
        validate_identity(identity, spec.public_key)
    except IdentityError as error:
        raise ProxDeployError(str(error)) from error

    password = password_store.read(request.password_reference).rstrip("\r\n")
    installer.prepare(request)
    vmid = deployer.deploy(
        request,
        ProxmoxCredentials(
            host=request.node,
            user="root",
            password=password,
        ),
    )
    installer.install(request, vmid, identity)
    return vmid
