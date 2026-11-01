from __future__ import annotations

from datetime import UTC, datetime

import pytest
from vikunja_provision.models import Bot, Declaration, ProvisionError, Share, Token
from vikunja_provision.workflow import Plan, apply, plan

from .fakes import MemoryCredentials, MemoryVikunja

NOW = datetime(2026, 11, 1, tzinfo=UTC)


def prepare(
    declaration: Declaration,
    api: MemoryVikunja,
    store: MemoryCredentials,
    *,
    rotate: bool = False,
) -> Plan:
    return plan(declaration, api, store, rotate_token=rotate, now=NOW)


def provision(declaration: Declaration, api: MemoryVikunja, store: MemoryCredentials) -> None:
    apply(declaration, prepare(declaration, api, store), api, store)


def test_plan_does_not_change_remote_or_local_state(declaration: Declaration) -> None:
    api = MemoryVikunja()
    store = MemoryCredentials()

    prepared = prepare(declaration, api, store)

    assert prepared.changes
    assert api.bots() == []
    assert api.tokens(1) == []
    assert api.shares(10) == []
    assert store.load() is None


def test_apply_creates_access_and_token_then_repeats_without_changes(
    declaration: Declaration,
) -> None:
    api = MemoryVikunja()
    store = MemoryCredentials()
    provision(declaration, api, store)
    original = store.load()

    provision(declaration, api, store)

    assert prepare(declaration, api, store).changes == []
    assert len(api.bots()) == 1
    assert api.shares(10) == [Share(username="bot-agents", permission=1)]
    assert len(api.tokens(1)) == 1
    assert store.load() == original
    assert original is not None
    assert original.token.get_secret_value() == "tk_secret_1"


def test_apply_updates_name_status_and_access_without_touching_other_users(
    declaration: Declaration,
) -> None:
    api = MemoryVikunja(
        bot_records=[Bot(id=1, username="bot-agents", name="Old name", status=2)],
        project_shares={
            10: [Share(username="bot-agents", permission=0), Share(username="human", permission=2)],
            20: [Share(username="bot-agents", permission=0)],
        },
    )
    store = MemoryCredentials()

    provision(declaration, api, store)

    assert api.bots() == [Bot(id=1, username="bot-agents", name="Coding agents", status=0)]
    assert Share(username="human", permission=2) in api.shares(10)
    assert Share(username="bot-agents", permission=1) in api.shares(10)
    assert api.shares(20) == [Share(username="bot-agents", permission=0)]


@pytest.mark.parametrize("change", ["permissions", "title", "expiry"])
def test_changed_token_requires_explicit_rotation(declaration: Declaration, change: str) -> None:
    api = MemoryVikunja()
    store = MemoryCredentials()
    provision(declaration, api, store)
    previous = store.load()
    if change == "permissions":
        declaration.token.permissions["tasks"].append("create")
    elif change == "title":
        declaration.token.title = "renamed"
    else:
        declaration.token.expires_at = declaration.token.expires_at.replace(year=2101)

    with pytest.raises(ProvisionError, match="permissions or expiry changed"):
        provision(declaration, api, store)

    assert store.load() == previous
    apply(declaration, prepare(declaration, api, store, rotate=True), api, store)
    assert [token.id for token in api.tokens(1)] == [2]
    assert store.load() is not None
    assert store.load() != previous
    assert prepare(declaration, api, store).changes == []


@pytest.mark.parametrize("missing", ["local", "remote"])
def test_missing_credentials_or_remote_token_require_rotation(
    declaration: Declaration, missing: str
) -> None:
    api = MemoryVikunja()
    store = MemoryCredentials()
    provision(declaration, api, store)
    if missing == "local":
        store.credentials = None
    else:
        api.token_records.clear()

    with pytest.raises(ProvisionError, match="--rotate-token"):
        prepare(declaration, api, store)

    apply(declaration, prepare(declaration, api, store, rotate=True), api, store)
    assert len(api.tokens(1)) == 1


@pytest.mark.parametrize("change", ["server", "bot", "token"])
def test_credentials_cannot_be_reused_for_another_identity(
    declaration: Declaration, change: str
) -> None:
    api = MemoryVikunja()
    store = MemoryCredentials()
    provision(declaration, api, store)
    assert store.credentials is not None
    if change == "server":
        store.credentials.server = "https://elsewhere.example.test"
    elif change == "bot":
        api.bot_records.clear()
    else:
        store.credentials.token_id = 1234

    with pytest.raises(ProvisionError, match=r"different server or bot|--rotate-token"):
        prepare(declaration, api, store)


def test_duplicate_token_names_fail_without_guessing_which_to_revoke(
    declaration: Declaration,
) -> None:
    api = MemoryVikunja()
    store = MemoryCredentials()
    provision(declaration, api, store)
    api.issue_token(1, declaration.token)

    with pytest.raises(ProvisionError, match="Multiple tokens"):
        prepare(declaration, api, store, rotate=True)

    assert len(api.tokens(1)) == 2


def test_token_rename_cannot_replace_an_unrelated_token(declaration: Declaration) -> None:
    api = MemoryVikunja()
    store = MemoryCredentials()
    provision(declaration, api, store)
    declaration.token.title = "already-used"
    api.issue_token(1, declaration.token)

    with pytest.raises(ProvisionError, match="already used by another"):
        prepare(declaration, api, store, rotate=True)

    assert len(api.tokens(1)) == 2


def test_other_bots_and_tokens_are_preserved(declaration: Declaration) -> None:
    api = MemoryVikunja(bot_records=[Bot(id=1, username="bot-other", name="Other", status=0)])
    unrelated = Token(
        id=100,
        title="unrelated",
        owner_id=2,
        permissions={"mcp": ["access"]},
        expires_at=declaration.token.expires_at,
    )
    api.token_records.append(unrelated)

    provision(declaration, api, MemoryCredentials())

    assert len(api.bots()) == 2
    assert unrelated in api.tokens(2)


def test_expired_declaration_fails_before_mutation(declaration: Declaration) -> None:
    api = MemoryVikunja()
    declaration.token.expires_at = NOW

    with pytest.raises(ProvisionError, match="future"):
        prepare(declaration, api, MemoryCredentials())

    assert api.bots() == []


def test_issuance_failure_keeps_old_credentials_and_can_be_retried(
    declaration: Declaration,
) -> None:
    api = MemoryVikunja()
    store = MemoryCredentials()
    provision(declaration, api, store)
    original = store.load()
    api.fail_issue = True

    with pytest.raises(ProvisionError, match="issuance failed"):
        apply(declaration, prepare(declaration, api, store, rotate=True), api, store)

    assert store.load() == original
    assert [token.id for token in api.tokens(1)] == [1]
    api.fail_issue = False
    apply(declaration, prepare(declaration, api, store, rotate=True), api, store)
    assert [token.id for token in api.tokens(1)] == [2]


@pytest.mark.parametrize("cleanup_fails", [False, True])
def test_save_failure_preserves_old_credentials_and_reports_cleanup(
    declaration: Declaration, cleanup_fails: bool
) -> None:
    api = MemoryVikunja()
    store = MemoryCredentials()
    provision(declaration, api, store)
    original = store.load()
    store.fail_save = True
    api.fail_revoke = cleanup_fails

    with pytest.raises(ProvisionError, match=r"may remain active|revoked the newly issued token"):
        apply(declaration, prepare(declaration, api, store, rotate=True), api, store)

    assert store.load() == original
    assert 1 in [token.id for token in api.tokens(1)]
    assert len(api.tokens(1)) == (2 if cleanup_fails else 1)


def test_revocation_failure_leaves_replacement_credentials_available(
    declaration: Declaration,
) -> None:
    api = MemoryVikunja()
    store = MemoryCredentials()
    provision(declaration, api, store)
    api.fail_revoke = True

    with pytest.raises(ProvisionError, match="New credentials saved, but previous token 1"):
        apply(declaration, prepare(declaration, api, store, rotate=True), api, store)

    assert store.credentials is not None
    assert store.credentials.token_id == 2
    assert len(api.tokens(1)) == 2
