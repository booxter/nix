from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path

from .errors import ToolError
from .process import ProcessRunner


@dataclass(frozen=True)
class AgeRecipientResolver:
    runner: ProcessRunner

    def derive(self, identity_file: Path) -> str:
        if not identity_file.is_file():
            raise ToolError(f"Age identity file not found: {identity_file}")

        identity_type = self._identity_type(identity_file)
        if identity_type.startswith("AGE-SECRET-KEY-"):
            recipient = self.runner.run(
                ["age-keygen", "-y", str(identity_file)]
            ).strip()
        elif identity_type.startswith("AGE-PLUGIN-SE-"):
            recipients = self._metadata_recipients(identity_file, "age1se1")
            if len(recipients) > 1:
                raise ToolError(
                    "Secure Enclave age identity contains multiple recipient "
                    f"metadata lines: {identity_file}"
                )
            recipient = (
                recipients[0]
                if recipients
                else self.runner.run(
                    ["age-plugin-se", "recipients", "-i", str(identity_file)]
                ).strip()
            )
        elif identity_type.startswith("AGE-PLUGIN-YUBIKEY-"):
            recipients = self._metadata_recipients(identity_file, "age1yubikey1")
            if len(recipients) != 1:
                raise ToolError(
                    "YubiKey age identity must contain exactly one recipient "
                    f"metadata line: {identity_file}"
                )
            recipient = recipients[0]
        else:
            raise ToolError(f"Unsupported age identity type in: {identity_file}")

        if not recipient:
            raise ToolError(f"Failed to derive age recipient from: {identity_file}")
        return recipient

    @staticmethod
    def _identity_type(identity_file: Path) -> str:
        for line in identity_file.read_text().splitlines():
            stripped = line.strip()
            if stripped and not stripped.startswith("#"):
                return stripped.split()[0]
        raise ToolError(f"Unsupported age identity type in: {identity_file}")

    @staticmethod
    def _metadata_recipients(identity_file: Path, prefix: str) -> list[str]:
        pattern = re.compile(rf"^#[^:]*:\s*({re.escape(prefix)}[0-9a-z]+)\s*$")
        recipients = {
            match.group(1)
            for line in identity_file.read_text().splitlines()
            if (match := pattern.fullmatch(line))
        }
        return sorted(recipients)
