from __future__ import annotations

import argparse
import json
import os
import sys
from collections.abc import Mapping, Sequence
from pathlib import Path
from typing import TextIO

from .adapters import (
    NixmoxerDeployer,
    PassPasswordStore,
    ProxDeployError,
    SubprocessRunner,
    load_nixmoxer_callback,
)
from .core import DeployRequest, PasswordStore, VmDeployer, deploy_vm


def load_vm_types(encoded: str) -> tuple[str, ...]:
    value: object = json.loads(encoded)
    if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
        raise ProxDeployError("PROX_DEPLOY_VM_TYPES_JSON must contain a JSON string array")
    return tuple(value)


def build_parser(vm_types: Sequence[str]) -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Deploy a NixOS VM through nixmoxer")
    parser.add_argument("vm_type", choices=vm_types, metavar="VM_TYPE")
    parser.add_argument("proxmox_host", metavar="PROXMOX_HOST")
    return parser


def run_cli(
    arguments: Sequence[str],
    *,
    vm_types: Sequence[str],
    password_store: PasswordStore,
    deployer: VmDeployer,
    stderr: TextIO,
) -> int:
    namespace = build_parser(vm_types).parse_args(arguments)
    try:
        deploy_vm(
            DeployRequest(
                vm_type=namespace.vm_type,
                proxmox_host=namespace.proxmox_host,
            ),
            password_store,
            deployer,
        )
    except ProxDeployError as error:
        print(f"prox-deploy: {error}", file=stderr)
        return 1
    return 0


def main(
    arguments: Sequence[str],
    *,
    environment: Mapping[str, str],
    stderr: TextIO,
    password_store: PasswordStore | None = None,
    deployer: VmDeployer | None = None,
) -> int:
    try:
        vm_types = load_vm_types(environment["PROX_DEPLOY_VM_TYPES_JSON"])
        pass_executable = Path(environment["PROX_DEPLOY_PASS"])
    except KeyError as error:
        print(f"prox-deploy: missing packaged setting {error.args[0]}", file=stderr)
        return 1
    except (json.JSONDecodeError, ProxDeployError) as error:
        print(f"prox-deploy: {error}", file=stderr)
        return 1

    if password_store is None:
        password_store = PassPasswordStore(pass_executable, SubprocessRunner())
    if deployer is None:
        deployer = NixmoxerDeployer(load_nixmoxer_callback, os.environ)

    return run_cli(
        arguments,
        vm_types=vm_types,
        password_store=password_store,
        deployer=deployer,
        stderr=stderr,
    )


def entrypoint() -> int:
    return main(sys.argv[1:], environment=os.environ, stderr=sys.stderr)
