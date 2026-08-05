from __future__ import annotations

import fnmatch
import os
import shutil
import tempfile
from collections.abc import Callable, Iterable
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Protocol, TextIO

from .models import Artifacts, BundleDefaults, FlashOptions
from .process import FlashError
from .remote import RemoteHba


class RemoteHbaFactory(Protocol):
    def __call__(self, host: str) -> RemoteHba: ...


def generated_remote_directory() -> str:
    timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    return f"/tmp/hba-flash-{timestamp}-{os.getpid()}"


@dataclass
class HbaFlashWorkflow:
    remote_factory: RemoteHbaFactory
    stderr: TextIO
    remote_directory_factory: Callable[[], str] = generated_remote_directory
    _temporary_directories: list[Path] = field(default_factory=list, init=False)
    _remote_directory: str | None = field(default=None, init=False)

    def note(self, message: str) -> None:
        print(f"[hba-flash] {message}", file=self.stderr)

    @staticmethod
    def _absolute(path: Path) -> Path:
        return path if path.is_absolute() else Path.cwd() / path

    @classmethod
    def _require_file(cls, path: Path) -> Path:
        absolute = cls._absolute(path)
        if not absolute.is_file():
            raise FlashError(f"file not found: {path}")
        return absolute

    def _prepare_bundle(self, label: str, path: Path) -> Path:
        absolute = self._absolute(path)
        if absolute.is_dir():
            return absolute
        if absolute.is_file() and absolute.suffix.casefold() == ".zip":
            directory = Path(tempfile.mkdtemp(prefix=f"hba-flash-{label}."))
            self._temporary_directories.append(directory)
            self.note(f"extracting {label} ZIP: {absolute}")
            shutil.unpack_archive(absolute, directory, "zip")
            return directory
        raise FlashError(f"{label} must be a directory or ZIP file: {path}")

    @staticmethod
    def _unique(paths: Iterable[Path]) -> tuple[Path, ...]:
        return tuple(dict.fromkeys(paths))

    @classmethod
    def _find(cls, root: Path, *patterns: str) -> tuple[Path, ...]:
        files = sorted((path for path in root.rglob("*") if path.is_file()), key=str)
        return cls._unique(
            path
            for pattern in patterns
            for path in files
            if fnmatch.fnmatch(path.name.casefold(), pattern.casefold())
        )

    def _choose_one(self, label: str, values: Iterable[Path]) -> Path:
        candidates = tuple(values)
        if len(candidates) == 1:
            return candidates[0]
        if candidates:
            self.note(f"multiple {label} candidates found:")
            for candidate in candidates:
                print(f"  {candidate}", file=self.stderr)
            raise FlashError(f"please pass --{label} explicitly")
        raise FlashError(f"no {label} candidate found in the provided bundle(s)")

    def _resolve_sas3flash(
        self,
        explicit: Path | None,
        roots: tuple[Path, ...],
    ) -> Path:
        if explicit is not None:
            return self._require_file(explicit)
        if not roots:
            raise FlashError("pass --bundle, --sas3flash-bundle, or --sas3flash explicitly")
        preferred = self._unique(
            candidate
            for root in roots
            for candidate in root.rglob("sas3flash")
            if candidate.is_file()
            and candidate.as_posix().endswith(
                (
                    "/sas3flash_linux_x64_rel/sas3flash",
                    "/sas3flash_linux_amd64_rel/sas3flash",
                )
            )
        )
        if preferred:
            return self._choose_one("sas3flash", preferred)
        candidates = tuple(
            candidate
            for root in roots
            for candidate in self._find(root, "sas3flash", "sas3flash*", "sas3flsh*")
        )
        if candidates:
            self.note("found sas3flash candidates, but no Linux x64 binary:")
            for candidate in candidates:
                print(f"  {candidate}", file=self.stderr)
            raise FlashError("pass --sas3flash explicitly or provide a Linux sas3flash bundle")
        raise FlashError("no sas3flash binary found in the provided bundle(s)")

    def _resolve_firmware(
        self,
        explicit: Path | None,
        roots: tuple[Path, ...],
    ) -> Path:
        if explicit is not None:
            return self._require_file(explicit)
        if not roots:
            raise FlashError("pass --bundle, --firmware-bundle, or --firmware explicitly")
        direct = tuple(
            candidate
            for root in roots
            for candidate in self._find(
                root,
                "*9305*24i*IT*.bin",
                "*9305*24i*.bin",
                "*9305*.bin",
                "*3224*.bin",
            )
        )
        if len(direct) == 1:
            return direct[0]
        fallback = tuple(
            candidate
            for root in roots
            for candidate in self._find(root, "*.bin", "*.fw")
            if candidate.suffix.casefold() != ".rom"
            and not candidate.name.casefold().startswith("mptsas3")
        )
        return self._choose_one("firmware", (*direct, *fallback))

    def _artifacts(self, options: FlashOptions, defaults: BundleDefaults) -> Artifacts:
        bundle = self._prepare_bundle("bundle", options.bundle) if options.bundle else None
        sas_bundle = (
            self._prepare_bundle("sas3flash-bundle", options.sas3flash_bundle)
            if options.sas3flash_bundle
            else None
        )
        firmware_bundle = (
            self._prepare_bundle("firmware-bundle", options.firmware_bundle)
            if options.firmware_bundle
            else None
        )
        if bundle is None and sas_bundle is None and options.sas3flash is None:
            sas_bundle = defaults.sas3flash
            if sas_bundle is not None:
                self.note(f"using default sas3flash bundle: {sas_bundle}")
        if bundle is None and firmware_bundle is None and options.firmware is None:
            firmware_bundle = defaults.firmware
            if firmware_bundle is not None:
                self.note(f"using default firmware bundle: {firmware_bundle}")
        sas_roots = tuple(path for path in (sas_bundle, bundle) if path is not None)
        firmware_roots = tuple(path for path in (firmware_bundle, bundle) if path is not None)
        return Artifacts(
            sas3flash=self._resolve_sas3flash(options.sas3flash, sas_roots),
            firmware=self._resolve_firmware(options.firmware, firmware_roots),
            optionrom=(self._require_file(options.optionrom) if options.optionrom else None),
        )

    def _cleanup(self, options: FlashOptions, remote: RemoteHba) -> None:
        if self._remote_directory is not None and not options.keep_remote:
            remote.cleanup(self._remote_directory)
        for directory in self._temporary_directories:
            shutil.rmtree(directory, ignore_errors=True)

    def execute(self, options: FlashOptions, defaults: BundleDefaults) -> None:
        remote_host = self.remote_factory(options.host)
        try:
            artifacts = self._artifacts(options, defaults)
            self.note(f"local sas3flash: {artifacts.sas3flash}")
            self.note(f"local firmware: {artifacts.firmware}")
            if artifacts.optionrom is not None:
                self.note(f"local optionrom: {artifacts.optionrom}")

            self.note(f"remote preflight on {options.host}")
            remote_host.preflight(options.controller)
            remote_directory = self.remote_directory_factory()
            self._remote_directory = remote_directory
            self.note(f"staging utility and firmware in {remote_directory} on {options.host}")
            remote_host.stage(remote_directory, artifacts)
            self.note("checking staged sas3flash utility")
            remote_host.check_tool(remote_directory, options.controller)
            if not options.flash:
                self.note("preflight finished; rerun with --flash to update firmware")
                return
            if options.quiesce:
                self.note(f"stopping media and NFS services on {options.host}")
                remote_host.quiesce()
                self.note(f"verifying {options.host} is quiesced before flash")
                remote_host.verify_quiesced()
            self.note(f"flashing controller {options.controller} on {options.host}")
            remote_host.flash(
                remote_directory,
                options.controller,
                artifacts.optionrom is not None,
            )
            if options.reboot:
                self.note(f"rebooting {options.host}")
                remote_host.reboot()
            else:
                self.note(f"flash completed; reboot {options.host} before using the controller")
        finally:
            self._cleanup(options, remote_host)
