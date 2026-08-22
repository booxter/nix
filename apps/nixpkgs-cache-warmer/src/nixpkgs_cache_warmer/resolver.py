from __future__ import annotations

from pathlib import Path

from pydantic import ValidationError

from nixpkgs_cache_warmer.commands import CommandError, CommandRunner
from nixpkgs_cache_warmer.models import FlakeMetadata, ResolvedSource


class SourceResolver:
    def __init__(self, runner: CommandRunner, nix: Path) -> None:
        self._runner = runner
        self._nix = nix

    def resolve(self, reference: str) -> ResolvedSource:
        result = self._runner.run(
            (str(self._nix), "flake", "metadata", "--refresh", "--json", reference)
        )
        if result.returncode != 0:
            detail = result.stderr.strip() or f"exit status {result.returncode}"
            raise CommandError(f"failed to resolve {reference}: {detail}")
        try:
            metadata = FlakeMetadata.model_validate_json(result.stdout)
        except ValidationError as error:
            raise CommandError(f"Nix returned invalid metadata for {reference}: {error}") from error
        if metadata.locked.rev is None:
            raise CommandError(f"{reference} did not resolve to a Git revision")
        return ResolvedSource(
            reference=reference,
            revision=metadata.locked.rev,
            source=metadata.path,
        )
