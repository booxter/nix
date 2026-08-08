import xml.etree.ElementTree as ET
from pathlib import Path

from .errors import CueSplitterError


def read_api_key(config_path: Path) -> str:
    try:
        root = ET.parse(config_path).getroot()
    except (OSError, ET.ParseError) as error:
        raise CueSplitterError(f"cannot read Lidarr config {config_path}: {error}") from error
    api_key = (root.findtext("ApiKey") or "").strip()
    if not api_key:
        raise CueSplitterError(f"Lidarr config {config_path} does not contain ApiKey")
    return api_key
