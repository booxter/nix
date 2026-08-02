from __future__ import annotations

import os
import shutil
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol

from .age import AgeRecipientResolver
from .errors import ToolError
from .model import JsonValue
from .policy import SopsPolicy
from .process import ProcessRunner
from .repository import RuntimeEnvironment, SecretDomain, SecretRepository
from .runtime_key import (
    CommandAgeKeyGenerator,
    RuntimeKeyError,
    ensure_runtime_key,
)
from .secrets import SopsBackend, load_yaml, write_atomic

_RUNTIME_KEY = Path("/var/lib/sops-nix/key.txt")


class RuntimeKeyProvider(Protocol):
    def recipient(self, host: str, user: str, *, local: bool) -> str: ...


class OperatorRecipientProvider(Protocol):
    def recipient(self, domain: SecretDomain) -> str: ...


@dataclass(frozen=True)
class CommandRuntimeKeyProvider:
    runner: ProcessRunner
    repo_root: Path
    target_system: str

    def recipient(self, host: str, user: str, *, local: bool) -> str:
        if local:
            return self._local_recipient()
        return self._remote_recipient(f"{user}@{host}")

    def _local_recipient(self) -> str:
        age_keygen = Path(self._executable("age-keygen"))
        if os.geteuid() == 0:
            try:
                return ensure_runtime_key(
                    _RUNTIME_KEY, CommandAgeKeyGenerator(age_keygen)
                )
            except RuntimeKeyError as error:
                raise ToolError(str(error)) from error
        return self.runner.run(
            [
                self._executable("sudo"),
                sys.executable,
                "-m",
                "sops_tools.runtime_key",
                "--age-keygen",
                str(age_keygen),
                str(_RUNTIME_KEY),
            ]
        ).strip()

    def _remote_recipient(self, target: str) -> str:
        package = self._build_target_package()
        self.runner.run(["nix", "copy", "--to", f"ssh://{target}", str(package)])
        remote_root = self.runner.run(["ssh", target, "id", "-u"]).strip() == "0"
        privilege = [] if remote_root else ["sudo"]
        output = self.runner.run_streaming(
            [
                "ssh",
                "-tt",
                target,
                *privilege,
                str(package / "bin/sops-runtime-key"),
                "--age-keygen",
                "age-keygen",
                str(_RUNTIME_KEY),
            ]
        )
        recipients = [
            line.strip()
            for line in output.replace("\r", "").splitlines()
            if line.strip().startswith("age1")
        ]
        if not recipients or not recipients[-1]:
            raise ToolError(f"Failed to read age public key from remote host: {target}")
        return recipients[-1]

    def _build_target_package(self) -> Path:
        flake = f"path:{self.repo_root}#packages.{self.target_system}.sops-tools"
        outputs = self.runner.run(
            ["nix", "build", "--no-link", "--print-out-paths", flake]
        ).splitlines()
        if len(outputs) != 1 or not outputs[0].startswith("/nix/store/"):
            raise ToolError(
                f"Failed to build sops-tools for target system {self.target_system}."
            )
        return Path(outputs[0])

    @staticmethod
    def _executable(name: str) -> str:
        executable = shutil.which(name)
        if executable is None:
            raise ToolError(f"Required command not found: {name}")
        return executable


@dataclass(frozen=True)
class CommandOperatorRecipientProvider:
    runtime: RuntimeEnvironment
    runner: ProcessRunner
    resolver: AgeRecipientResolver

    def recipient(self, domain: SecretDomain) -> str:
        configured = self.runtime.values.get("SOPS_AGE_KEY_FILE")
        if configured:
            identity = Path(configured)
        elif domain.name == "main":
            identity = self.runtime.home / ".config/sops/age/keys.txt"
        elif domain.identity_file is not None:
            identity = domain.identity_file
        else:
            identity = self.runtime.domain_identity_file(domain.name)

        if domain.name == "work" and not identity.is_file():
            self._initialize_work_identity(identity)
        if not identity.is_file():
            raise ToolError(
                f"Local age key file not found: {identity}\n"
                "Set SOPS_AGE_KEY_FILE or create the identity first."
            )
        return self.resolver.derive(identity)

    def _initialize_work_identity(self, identity: Path) -> None:
        if self.runtime.system_name != "Darwin":
            raise ToolError(
                "The work operator identity must be initialized on macOS with "
                "Secure Enclave support."
            )
        identity.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        identity.parent.chmod(0o700)
        self.runner.run(
            [
                "age-plugin-se",
                "keygen",
                "--access-control",
                "current-biometry",
                "-o",
                str(identity),
            ],
            capture_output=False,
        )
        identity.chmod(0o600)


@dataclass(frozen=True)
class BootstrapResult:
    messages: tuple[str, ...]


@dataclass
class BootstrapService:
    runtime: RuntimeEnvironment
    repository: SecretRepository
    sops: SopsBackend
    runtime_keys: RuntimeKeyProvider
    operator: OperatorRecipientProvider

    def bootstrap(
        self,
        host: str,
        user: str,
        *,
        local: bool,
        has_tty: bool,
    ) -> BootstrapResult:
        self.runtime.assert_domain_host(self.repository.domain, host)
        local = local or host == self.runtime.machine_hostname
        if not local and not has_tty:
            raise ToolError(
                f"Error: no TTY available for sudo on {host}. "
                "Run this command from a real terminal."
            )

        runtime_recipient = self.runtime_keys.recipient(host, user, local=local)
        if not runtime_recipient:
            raise ToolError(f"Failed to read age public key for {host}.")
        operator_recipient = self.operator.recipient(self.repository.domain)

        policy_path = self.runtime.repo_root / ".sops.yaml"
        created_policy = not policy_path.is_file()
        policy = SopsPolicy.create() if created_policy else SopsPolicy.load(policy_path)
        recipients = [runtime_recipient, operator_recipient]
        control = self._control_plane_recipient(policy, operator_recipient)
        if control is not None:
            recipients.append(control)
        policy.ensure_host_rule(self.repository.domain.name, host, recipients)
        policy.write(policy_path)

        messages = ["Created .sops.yaml." if created_policy else "Updated .sops.yaml."]
        self.repository.directory.mkdir(parents=True, exist_ok=True)
        secret = self.repository.secret(host)
        if secret.is_file():
            messages.append(
                f"{secret.relative_to(self.runtime.repo_root)} already exists."
            )
        else:
            plaintext: JsonValue = {}
            if self.repository.template.is_file():
                plaintext = load_yaml(self.repository.template)
            encrypted = self.sops.encrypt_data(secret, plaintext)
            if not encrypted:
                raise ToolError(f"Failed to create encrypted secret for {secret}.")
            write_atomic(secret, encrypted)
            relative = secret.relative_to(self.runtime.repo_root)
            messages.append(f"Created encrypted {relative}.")
        return BootstrapResult(tuple(messages))

    def _control_plane_recipient(
        self, policy: SopsPolicy, operator_recipient: str
    ) -> str | None:
        if self.repository.domain.name != "main":
            return None
        return next(
            (
                recipient
                for recipient in policy.recipients_for_rule("secrets/main/pki\\.yaml$")
                if recipient != operator_recipient
            ),
            None,
        )
