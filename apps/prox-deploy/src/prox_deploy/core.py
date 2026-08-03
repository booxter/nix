from __future__ import annotations

from dataclasses import dataclass
from typing import Protocol


@dataclass(frozen=True)
class DeployRequest:
    vm_type: str
    proxmox_host: str

    @property
    def password_reference(self) -> str:
        return f"host/{self.proxmox_host}/root"


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
    def deploy(self, request: DeployRequest, credentials: ProxmoxCredentials) -> None: ...


def deploy_vm(
    request: DeployRequest,
    password_store: PasswordStore,
    deployer: VmDeployer,
) -> None:
    password = password_store.read(request.password_reference)
    deployer.deploy(
        request,
        ProxmoxCredentials(
            host=request.proxmox_host,
            user="root",
            password=password,
        ),
    )
