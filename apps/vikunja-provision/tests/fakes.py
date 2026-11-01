from __future__ import annotations

from dataclasses import dataclass, field

from pydantic import SecretStr
from vikunja_provision.models import (
    Bot,
    BotSpec,
    Credentials,
    IssuedToken,
    ProvisionError,
    Share,
    Token,
    TokenSpec,
)


@dataclass
class MemoryVikunja:
    bot_records: list[Bot] = field(default_factory=list)
    project_shares: dict[int, list[Share]] = field(default_factory=dict)
    token_records: list[Token] = field(default_factory=list)
    fail_issue: bool = False
    fail_revoke: bool = False
    next_token_id: int = 1

    def bots(self) -> list[Bot]:
        return self.bot_records.copy()

    def shares(self, project_id: int) -> list[Share]:
        return self.project_shares.get(project_id, []).copy()

    def tokens(self, bot_id: int) -> list[Token]:
        return [token for token in self.token_records if token.owner_id == bot_id]

    def create_bot(self, desired: BotSpec) -> Bot:
        bot = Bot(id=len(self.bot_records) + 1, **desired.model_dump(), status=0)
        self.bot_records.append(bot)
        return bot

    def update_bot(self, bot: Bot, desired: BotSpec) -> None:
        self.bot_records = [
            Bot(id=current.id, **desired.model_dump(), status=0)
            if current.id == bot.id
            else current
            for current in self.bot_records
        ]

    def set_share(self, project_id: int, share: Share, *, exists: bool) -> None:
        shares = self.project_shares.setdefault(project_id, [])
        current = next((item for item in shares if item.username == share.username), None)
        if exists != (current is not None):
            raise ProvisionError("Share was changed concurrently")

        self.project_shares[project_id] = [
            item for item in shares if item.username != share.username
        ] + [share]

    def issue_token(self, bot_id: int, desired: TokenSpec) -> IssuedToken:
        if self.fail_issue:
            raise ProvisionError("Token issuance failed")

        token = IssuedToken(
            id=self.next_token_id,
            owner_id=bot_id,
            token=SecretStr(f"tk_secret_{self.next_token_id}"),
            **desired.model_dump(),
        )
        self.next_token_id += 1
        self.token_records.append(Token.model_validate(token.model_dump()))
        return token

    def delete_token(self, token_id: int) -> None:
        if self.fail_revoke:
            raise ProvisionError("Token revocation failed")

        self.token_records = [token for token in self.token_records if token.id != token_id]


@dataclass
class MemoryCredentials:
    credentials: Credentials | None = None
    fail_save: bool = False

    def load(self) -> Credentials | None:
        return self.credentials

    def save(self, credentials: Credentials) -> None:
        if self.fail_save:
            raise OSError("Disk is full")

        self.credentials = credentials
