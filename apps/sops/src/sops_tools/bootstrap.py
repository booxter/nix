from __future__ import annotations

import shutil
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol

from atomic_file_writes import write_text_atomic

from .age import AgeRecipientResolver
from .errors import ToolError
from .model import JsonValue, deep_merge
from .policy import SopsPolicy
from .process import ProcessRunner
from .repository import Realm, RuntimeEnvironment, SecretRepository
from .secrets import SopsBackend, load_yaml

_HOST_KEY_NAME = "ssh_host_ed25519_key.pub"


class HostRecipientProvider(Protocol):
    def recipient(self, host: str) -> str: ...


class OperatorRecipientProvider(Protocol):
    def recipient(self, realm: Realm) -> str: ...


@dataclass(frozen=True)
class CommandHostRecipientProvider:
    runner: ProcessRunner
    repo_root: Path

    def recipient(self, host: str) -> str:
        candidates = [
            path
            for platform in ("nixos", "darwin")
            if (path := self.repo_root / platform / host / _HOST_KEY_NAME).is_file()
        ]
        if not candidates:
            raise ToolError(f"No committed Ed25519 SSH host key found for: {host}")
        if len(candidates) > 1:
            raise ToolError(f"Multiple committed Ed25519 SSH host keys found for: {host}")
        recipient = self.runner.run(
            [self._executable("ssh-to-age"), "-i", str(candidates[0])]
        ).strip()
        if not recipient.startswith("age1"):
            raise ToolError(f"Failed to derive age recipient from SSH host key for: {host}")
        return recipient

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

    def recipient(self, realm: Realm) -> str:
        configured = self.runtime.values.get("SOPS_AGE_KEY_FILE")
        if configured:
            identity = Path(configured)
        elif realm.name == "home":
            identity = self.runtime.home / ".config/sops/age/keys.txt"
        elif realm.identity_file is not None:
            identity = realm.identity_file
        else:
            identity = self.runtime.realm_identity_file(realm.name)

        if realm.name == "work" and not identity.is_file():
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
    host_recipients: HostRecipientProvider
    operator: OperatorRecipientProvider

    def bootstrap(self, host: str) -> BootstrapResult:
        self.runtime.assert_realm_host(self.repository.realm, host)
        host_recipient = self.host_recipients.recipient(host)
        operator_recipient = self.operator.recipient(self.repository.realm)

        recipients = [host_recipient, operator_recipient]
        if self.repository.realm.name == "home":
            recipients.append(self.host_recipients.recipient("pki"))
        return self._update_host(host, recipients)

    def _update_host(
        self,
        host: str,
        recipients: list[str],
    ) -> BootstrapResult:
        policy_path = self.runtime.repo_root / ".sops.yaml"
        created_policy = not policy_path.is_file()
        policy = SopsPolicy.create() if created_policy else SopsPolicy.load(policy_path)
        policy_changed = policy.ensure_host_rule(
            self.repository.realm.name,
            host,
            recipients,
        )
        original_policy = policy_path.read_text() if policy_path.is_file() else None
        policy.write(policy_path)

        messages = ["Created .sops.yaml." if created_policy else "Updated .sops.yaml."]
        try:
            messages.append(self._update_secret(host, policy_changed))
        except Exception:
            if original_policy is None:
                policy_path.unlink(missing_ok=True)
            else:
                write_text_atomic(policy_path, original_policy)
            raise
        return BootstrapResult(tuple(messages))

    def _update_secret(self, host: str, policy_changed: bool) -> str:
        self.repository.directory.mkdir(parents=True, exist_ok=True)
        secret = self.repository.secret(host)
        relative = secret.relative_to(self.runtime.repo_root)
        if secret.is_file():
            if not policy_changed:
                return f"{relative} already exists."
            plaintext = self.sops.decrypt_data(secret)
            encrypted = self.sops.encrypt_data(secret, plaintext)
            if not encrypted:
                raise ToolError(f"Failed to re-encrypt secret for {secret}.")
            write_text_atomic(secret, encrypted)
            return f"Re-encrypted {relative} for updated recipients."

        plaintext = self._template_for(host)
        encrypted = self.sops.encrypt_data(secret, plaintext)
        if not encrypted:
            raise ToolError(f"Failed to create encrypted secret for {secret}.")
        write_text_atomic(secret, encrypted)
        return f"Created encrypted {relative}."

    def _template_for(self, host: str) -> JsonValue:
        plaintext: JsonValue = {}
        if self.repository.template.is_file():
            plaintext = load_yaml(self.repository.template)
        host_template = self.repository.host_template(host)
        if host_template.is_file():
            plaintext = deep_merge(plaintext, load_yaml(host_template))
        return plaintext
