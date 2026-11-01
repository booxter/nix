from __future__ import annotations

from dataclasses import dataclass, field
from datetime import UTC, datetime

from pydantic import SecretStr
from vikunja_provision.models import (
    Bot,
    BotSpec,
    Credentials,
    Declaration,
    IssuedToken,
    Project,
    ProvisionError,
    Share,
    SopsTarget,
    Token,
    TokenSpec,
)
from vikunja_provision.storage import CredentialStore
from vikunja_provision.workflow import Plan, apply, plan


@dataclass
class MemoryVikunja:
    bot_records: list[Bot] = field(default_factory=list)
    project_records: list[Project] = field(
        default_factory=lambda: [Project(id=9, title="Other"), Project(id=10, title="Homelab")]
    )
    project_shares: dict[int, list[Share]] = field(default_factory=dict)
    token_records: list[Token] = field(default_factory=list)
    fail_issue: bool = False
    fail_revoke: bool = False
    next_token_id: int = 1

    def bots(self) -> list[Bot]:
        return self.bot_records.copy()

    def projects(self) -> list[Project]:
        return self.project_records.copy()

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


@dataclass
class MemoryTokenStore:
    values: dict[str, SecretStr] = field(default_factory=dict)
    failing_reads: set[str] = field(default_factory=set)
    failing_writes: set[str] = field(default_factory=set)

    def read(self, host: str, target: SopsTarget) -> SecretStr | None:
        if host in self.failing_reads:
            raise ProvisionError(f"Could not read SOPS secret for {host}")

        return self.values.get(host)

    def write(self, host: str, target: SopsTarget, value: SecretStr) -> None:
        if host in self.failing_writes:
            raise ProvisionError(f"Could not update SOPS secret for {host}")

        self.values[host] = value


def seat_targets() -> dict[str, SopsTarget]:
    return {
        host: SopsTarget(realm="home", key="agents/vikunja/org/agents/authorization")
        for host in ("frame", "mair", "mmini")
    }


def prepare(
    declaration: Declaration,
    api: MemoryVikunja,
    store: CredentialStore,
    *,
    rotate: bool = False,
) -> Plan:
    return plan(declaration, api, store, rotate_token=rotate, now=datetime(2026, 11, 1, tzinfo=UTC))


def provision(declaration: Declaration, api: MemoryVikunja, store: CredentialStore) -> None:
    apply(declaration, prepare(declaration, api, store), api, store)
