from dataclasses import dataclass
from pathlib import Path

from codex_tools.errors import CodexToolsError
from codex_tools.json import decode_object
from codex_tools.payloads import AuthPayload, validate_payload


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

        payload = validate_payload(AuthPayload, document, source=f"Codex auth file {path}")
        tokens = payload.tokens
        access_token = tokens.access_token if tokens is not None else None
        if not access_token:
            raise CodexToolsError(f"No access token found in {path}")
        return cls(
            access_token=access_token,
            account_id=tokens.account_id if tokens is not None else None,
        )
