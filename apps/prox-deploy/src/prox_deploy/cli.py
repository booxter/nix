from __future__ import annotations

import argparse
import os
import sys
from collections.abc import Mapping, Sequence
from pathlib import Path
from typing import TextIO

from pydantic import TypeAdapter, ValidationError

from .adapters import (
    NixmoxerDeployer,
    PassPasswordStore,
    SubprocessRunner,
    load_nixmoxer_callback,
)
from .core import (
    DeployRequest,
    GuestInstaller,
    PasswordStore,
    ProxDeployError,
    VmDeployer,
    VmSpec,
    deploy_vm,
)
from .installer import SshGuestInstaller, SystemClock


def load_vm_specs(encoded: str) -> dict[str, VmSpec]:
    return TypeAdapter(dict[str, VmSpec]).validate_json(encoded)


def build_parser(vm_types: Sequence[str]) -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Deploy a NixOS VM through nixmoxer")
    parser.add_argument("vm_type", choices=vm_types, metavar="VM_TYPE")
    parser.add_argument("proxmox_node", metavar="PROXMOX_NODE")
    return parser


def run_cli(
    arguments: Sequence[str],
    *,
    vm_specs: Mapping[str, VmSpec],
    password_store: PasswordStore,
    deployer: VmDeployer,
    installer: GuestInstaller,
    stderr: TextIO,
) -> int:
    namespace = build_parser(tuple(vm_specs)).parse_args(arguments)
    try:
        spec = vm_specs[namespace.vm_type]
        if namespace.proxmox_node not in spec.nodes:
            allowed = ", ".join(spec.nodes)
            raise ProxDeployError(
                f"node {namespace.proxmox_node} is not in VM {namespace.vm_type}'s cluster; "
                f"choose one of: {allowed}"
            )
        vmid = deploy_vm(
            DeployRequest(
                vm_type=namespace.vm_type,
                node=namespace.proxmox_node,
            ),
            spec,
            password_store,
            deployer,
            installer,
        )
    except ProxDeployError as error:
        print(f"prox-deploy: {error}", file=stderr)
        return 1
    print(f"Installed {namespace.vm_type} on {namespace.proxmox_node} (VM {vmid})", file=stderr)
    return 0


def main(
    arguments: Sequence[str],
    *,
    environment: Mapping[str, str],
    stderr: TextIO,
    password_store: PasswordStore | None = None,
    deployer: VmDeployer | None = None,
    installer: GuestInstaller | None = None,
) -> int:
    try:
        vm_specs = load_vm_specs(environment["PROX_DEPLOY_VM_SPECS_JSON"])
        pass_executable = Path(environment["PROX_DEPLOY_PASS"])
        ssh_executable = Path(environment["PROX_DEPLOY_SSH"])
    except KeyError as error:
        print(f"prox-deploy: missing packaged setting {error.args[0]}", file=stderr)
        return 1
    except ValidationError as error:
        print(f"prox-deploy: {error}", file=stderr)
        return 1

    if password_store is None:
        password_store = PassPasswordStore(pass_executable, SubprocessRunner())
    if deployer is None:
        deployer = NixmoxerDeployer(load_nixmoxer_callback, os.environ)
    if installer is None:
        installer = SshGuestInstaller(ssh_executable, SubprocessRunner(), SystemClock(), stderr)

    return run_cli(
        arguments,
        vm_specs=vm_specs,
        password_store=password_store,
        deployer=deployer,
        installer=installer,
        stderr=stderr,
    )


def entrypoint() -> int:
    return main(sys.argv[1:], environment=os.environ, stderr=sys.stderr)
