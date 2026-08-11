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


def load_vm_nodes(encoded: str) -> dict[str, tuple[str, ...]]:
    value: object = json.loads(encoded)
    if not isinstance(value, dict) or not all(
        isinstance(name, str)
        and isinstance(nodes, list)
        and nodes
        and all(isinstance(node, str) for node in nodes)
        for name, nodes in value.items()
    ):
        raise ProxDeployError(
            "PROX_DEPLOY_VM_NODES_JSON must map VM names to non-empty node arrays"
        )
    return {name: tuple(nodes) for name, nodes in value.items()}


def build_parser(vm_types: Sequence[str]) -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Deploy a NixOS VM through nixmoxer")
    parser.add_argument("vm_type", choices=vm_types, metavar="VM_TYPE")
    parser.add_argument("proxmox_node", metavar="PROXMOX_NODE")
    return parser


def run_cli(
    arguments: Sequence[str],
    *,
    vm_nodes: Mapping[str, tuple[str, ...]],
    password_store: PasswordStore,
    deployer: VmDeployer,
    stderr: TextIO,
) -> int:
    namespace = build_parser(tuple(vm_nodes)).parse_args(arguments)
    try:
        if namespace.proxmox_node not in vm_nodes[namespace.vm_type]:
            allowed = ", ".join(vm_nodes[namespace.vm_type])
            raise ProxDeployError(
                f"node {namespace.proxmox_node} is not in VM {namespace.vm_type}'s cluster; "
                f"choose one of: {allowed}"
            )
        deploy_vm(
            DeployRequest(
                vm_type=namespace.vm_type,
                node=namespace.proxmox_node,
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
        vm_nodes = load_vm_nodes(environment["PROX_DEPLOY_VM_NODES_JSON"])
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
        vm_nodes=vm_nodes,
        password_store=password_store,
        deployer=deployer,
        stderr=stderr,
    )


def entrypoint() -> int:
    return main(sys.argv[1:], environment=os.environ, stderr=sys.stderr)
