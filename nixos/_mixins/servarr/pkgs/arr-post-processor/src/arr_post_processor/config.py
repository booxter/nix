import xml.etree.ElementTree as ET
from pathlib import Path

from .errors import PostProcessorError


def read_api_key(config_path: Path) -> str:
    try:
        root = ET.parse(config_path).getroot()
    except (OSError, ET.ParseError) as error:
        raise PostProcessorError(f"cannot read Arr config {config_path}: {error}") from error
    api_key = (root.findtext("ApiKey") or "").strip()
    if not api_key:
        raise PostProcessorError(f"Arr config {config_path} does not contain ApiKey")
    return api_key


def read_environment_value(path: Path, name: str) -> str:
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as error:
        raise PostProcessorError(f"cannot read environment file {path}: {error}") from error
    matches = [line.partition("=")[2] for line in lines if line.partition("=")[0] == name]
    if len(matches) != 1 or not matches[0]:
        raise PostProcessorError(f"environment file {path} does not contain one {name}")
    return matches[0]
