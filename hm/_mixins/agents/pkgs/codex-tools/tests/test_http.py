import json
from pathlib import Path
from urllib.parse import quote

import pytest

from codex_tools.errors import CodexToolsError
from codex_tools.http import UrllibJsonHttpClient


def data_url(content: str, media_type: str = "application/json") -> str:
    return f"data:{media_type},{quote(content)}"


def test_reads_json_without_an_external_http_command() -> None:
    client = UrllibJsonHttpClient()

    assert client.get_json(
        data_url(json.dumps({"value": 42})),
        headers={"Authorization": "Bearer secret"},
    ) == {"value": 42}


def test_reports_transport_failure(tmp_path: Path) -> None:
    client = UrllibJsonHttpClient()

    with pytest.raises(CodexToolsError, match="Request to .* failed"):
        client.get_json((tmp_path / "missing.json").as_uri(), headers={})


def test_reports_non_utf8_response() -> None:
    client = UrllibJsonHttpClient()

    with pytest.raises(CodexToolsError, match="is not UTF-8"):
        client.get_json("data:application/octet-stream,%FF", headers={})
