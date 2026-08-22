from pathlib import Path

from pydantic import BaseModel, ConfigDict


class PackageTarget(BaseModel):
    """A buildable maintained package selected from nixpkgs."""

    model_config = ConfigDict(frozen=True)

    drvPath: Path
    name: str
    pname: str
    outputs: tuple[Path, ...]
