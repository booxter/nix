from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from pydantic import ValidationError

from telegram_archive_service_tools.model import ChatIds, CredentialPaths
from telegram_archive_service_tools.runtime import Error


@dataclass(frozen=True)
class Credentials:
    api_id: str | None
    api_hash: str | None
    phone: str | None
    chat_ids: tuple[int, ...]

    @property
    def chat_ids_csv(self) -> str:
        return ",".join(str(chat_id) for chat_id in self.chat_ids)


def _read(path: Path, description: str) -> str:
    try:
        value = path.read_text().replace("\r", "").replace("\n", "")
    except OSError as error:
        raise Error(f"failed to read Telegram Archive {description} from {path}") from error
    if not value:
        raise Error(f"Telegram Archive {description} is empty: {path}")
    return value


def read_chat_ids(path: Path) -> tuple[int, ...]:
    try:
        return tuple(ChatIds.model_validate_json(path.read_text()).root)
    except OSError as error:
        raise Error(f"failed to read Telegram Archive chat IDs from {path}") from error
    except (ValidationError, ValueError) as error:
        raise Error(
            "Telegram Archive chat IDs must be a non-empty JSON array of integers"
        ) from error


def read_credentials(paths: CredentialPaths, *, telegram: bool) -> Credentials:
    return Credentials(
        api_id=_read(paths.api_id, "API ID") if telegram else None,
        api_hash=_read(paths.api_hash, "API hash") if telegram else None,
        phone=_read(paths.phone, "phone number") if telegram else None,
        chat_ids=read_chat_ids(paths.chat_ids),
    )


def from_systemd_directory(directory: Path, *, telegram: bool) -> Credentials:
    return read_credentials(
        CredentialPaths(
            api_id=directory / "api-id",
            api_hash=directory / "api-hash",
            phone=directory / "phone",
            chat_ids=directory / "chat-ids",
        ),
        telegram=telegram,
    )


def apply(environment: dict[str, str], credentials: Credentials) -> None:
    chat_ids = credentials.chat_ids_csv
    environment["DISPLAY_CHAT_IDS"] = chat_ids
    if credentials.api_id is not None:
        assert credentials.api_hash is not None
        assert credentials.phone is not None
        environment.update(
            TELEGRAM_API_ID=credentials.api_id,
            TELEGRAM_API_HASH=credentials.api_hash,
            TELEGRAM_PHONE=credentials.phone,
            CHAT_IDS=chat_ids,
        )
