from __future__ import annotations

import pytest
from vikunja_provision.models import BotSpec, Declaration, ProjectSpec, SopsState, TokenSpec


@pytest.fixture
def declaration() -> Declaration:
    return Declaration(
        server="https://vi.example.test",
        bot=BotSpec(username="bot-agents", name="Coding agents"),
        projects=[ProjectSpec(title="Homelab", permission=1)],
        state=SopsState(host="org", realm="home", key="agents/vikunja/org/agents/credentials"),
        token=TokenSpec(
            title="agents",
            permissions={
                "mcp": ["access"],
                "tasks": ["read_all", "read_one", "update"],
                "tasks_comments": ["create", "read_all"],
            },
            expires_at="2100-01-01T00:00:00Z",
        ),
    )
