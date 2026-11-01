from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime

from vikunja_provision.api import Vikunja
from vikunja_provision.models import (
    Bot,
    Credentials,
    Declaration,
    Project,
    ProjectSpec,
    ProvisionError,
    Share,
    Token,
)
from vikunja_provision.storage import CredentialStore


@dataclass(frozen=True)
class ProjectAccess:
    desired: ProjectSpec
    project: Project
    current: Share | None

    @property
    def needs_update(self) -> bool:
        return self.current is None or self.current.permission != self.desired.permission


@dataclass(frozen=True)
class Plan:
    bot: Bot | None
    projects: tuple[ProjectAccess, ...]
    token: Token | None
    issue_token: bool
    changes: list[str]


def plan(
    desired: Declaration,
    api: Vikunja,
    store: CredentialStore,
    *,
    rotate_token: bool,
    now: datetime,
) -> Plan:
    if desired.token.expires_at <= now:
        raise ProvisionError("Token expiry must be in the future")

    credentials = store.load()
    bot = next((bot for bot in api.bots() if bot.username == desired.bot.username), None)
    if credentials is not None and (
        credentials.server != desired.server_url or bot is None or credentials.bot_id != bot.id
    ):
        raise ProvisionError("Credentials belong to a different server or bot; use another file")

    projects = _project_access(desired, api)
    tokens = api.tokens(bot.id) if bot is not None else []
    token = _managed_token(tokens, credentials, desired.token.title)
    issue_token = rotate_token or token is None
    if not rotate_token:
        _check_existing_token(token, credentials, desired)

    changes = _changes(desired, bot, projects)
    if issue_token:
        changes.append(f"{'rotate' if token else 'issue'} token {desired.token.title}")

    return Plan(bot, projects, token, issue_token, changes)


def _project_access(desired: Declaration, api: Vikunja) -> tuple[ProjectAccess, ...]:
    projects = api.projects()
    access = []
    for grant in desired.projects:
        matches = [project for project in projects if project.title == grant.title]
        if not matches:
            raise ProvisionError(f"Project {grant.title!r} was not found among accessible projects")

        if len(matches) > 1:
            raise ProvisionError(
                f"Project title {grant.title!r} is ambiguous; titles must be unique"
            )

        project = matches[0]
        current = next(
            (share for share in api.shares(project.id) if share.username == desired.bot.username),
            None,
        )
        access.append(ProjectAccess(grant, project, current))

    return tuple(access)


def _check_existing_token(
    token: Token | None, credentials: Credentials | None, desired: Declaration
) -> None:
    if token is None and credentials is None:
        return

    if token is None or credentials is None or credentials.token_id != token.id:
        raise ProvisionError("Remote token and saved credentials differ; use --rotate-token")

    if not token.matches(desired.token):
        raise ProvisionError("Token title, permissions or expiry changed; use --rotate-token")


def _managed_token(
    tokens: list[Token], credentials: Credentials | None, title: str
) -> Token | None:
    named = [token for token in tokens if token.title == title]
    if len(named) > 1:
        raise ProvisionError(
            "Multiple tokens have the declared title; resolve the duplicates first"
        )

    saved = next(
        (token for token in tokens if credentials is not None and token.id == credentials.token_id),
        None,
    )
    if saved is not None and named and saved.id != named[0].id:
        raise ProvisionError("The declared token title is already used by another token")

    # Follow the saved ID across title changes so rotation also revokes the old token.
    return saved or (named[0] if named else None)


def _changes(
    desired: Declaration, bot: Bot | None, projects: tuple[ProjectAccess, ...]
) -> list[str]:
    changes = []
    if bot is None:
        changes.append(f"create bot {desired.bot.username}")
    elif bot.name != desired.bot.name or bot.status != 0:
        changes.append(f"update bot {desired.bot.username} (name and active status)")

    changes.extend(
        f"set project {access.project.title!r} ({access.project.id}) permission "
        f"to {access.desired.permission}"
        for access in projects
        if access.needs_update
    )

    return changes


def apply(desired: Declaration, prepared: Plan, api: Vikunja, store: CredentialStore) -> None:
    bot = prepared.bot
    if bot is None:
        bot = api.create_bot(desired.bot)
    elif bot.name != desired.bot.name or bot.status != 0:
        api.update_bot(bot, desired.bot)

    for access in prepared.projects:
        if access.needs_update:
            api.set_share(
                access.project.id,
                Share(username=bot.username, permission=access.desired.permission),
                exists=access.current is not None,
            )

    if not prepared.issue_token:
        return

    issued = api.issue_token(bot.id, desired.token)
    credentials = Credentials(
        server=desired.server_url,
        bot_id=bot.id,
        token_id=issued.id,
        token=issued.token,
    )
    try:
        store.save(credentials)
    except OSError as error:
        try:
            api.delete_token(issued.id)
        except ProvisionError:
            raise ProvisionError(
                f"Could not save credentials; newly issued token {issued.id} may remain active"
            ) from error
        raise ProvisionError(
            "Could not save credentials; revoked the newly issued token"
        ) from error

    # Never invalidate the old credential until its replacement is durably saved.
    if prepared.token is not None:
        try:
            api.delete_token(prepared.token.id)
        except ProvisionError as error:
            raise ProvisionError(
                f"New credentials saved, but previous token {prepared.token.id} was not revoked"
            ) from error
