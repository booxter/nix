from dataclasses import dataclass
from pathlib import Path

from codex_tools.errors import CodexToolsError
from codex_tools.json import decode_object, object_value, string_value


@dataclass(frozen=True)
class CodexAuth:
    access_token: str
    account_id: str | None

    @classmethod
    def load(cls, path: Path) -> "CodexAuth":
        try:
            document = decode_object(path.read_text(encoding="utf-8"), source=str(path))
        except FileNotFoundError as error:
            raise CodexToolsError(f"Codex auth file not found: {path}") from error
        except OSError as error:
            raise CodexToolsError(f"Cannot read Codex auth file {path}: {error}") from error

        tokens = object_value(document, "tokens") or {}
        access_token = string_value(tokens.get("access_token"))
        if not access_token:
            raise CodexToolsError(f"No access token found in {path}")
        return cls(
            access_token=access_token,
            account_id=string_value(tokens.get("account_id")),
        )
