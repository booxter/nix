from __future__ import annotations

from pathlib import Path

import bcrypt
from atomic_file_writes import write_text_atomic
from pydantic import BaseModel, ConfigDict, Field


class AuthenticationEnvironment(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    system_user: str = Field(min_length=1, pattern=r"^[^\r\n=]+$")
    password_hash: str = Field(min_length=1, pattern=r"^[^\r\n]+$")

    def render(self) -> str:
        return (
            f"WS_SYSTEM_USER={self.system_user}\nWS_SYSTEM_PASSWORD=ws_hash@:{self.password_hash}\n"
        )


def read_secret(path: Path) -> str:
    return path.read_text(encoding="utf-8").rstrip("\r\n")


def hash_password(password: str, rounds: int = 12) -> str:
    return bcrypt.hashpw(password.encode(), bcrypt.gensalt(rounds=rounds)).decode()


def render_authentication(
    *,
    system_user: str,
    password_file: Path,
    output: Path,
) -> None:
    environment = AuthenticationEnvironment(
        system_user=system_user,
        password_hash=hash_password(read_secret(password_file)),
    )
    write_text_atomic(output, environment.render(), mode=0o400)
