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
