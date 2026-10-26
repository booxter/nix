# Coding agents

Codex and Claude Code share `context.md`, `skills/`, and
`host.hm.dev.agents.mcp` server declarations. Their packages come from unstable;
Claude is enabled in the NVIDIA developer profile through `programs.claude-code`.

MCP URLs and OAuth client IDs accept strings or `{ secret = "sops/key"; }`.
Existing encrypted keys retain their `codex/mcp/` names. Shared `instructions`
are appended to both clients' context; `startupTimeoutSec` only maps to Codex.

`common/_mixins/agents` renders secret-backed configuration with SOPS. Codex
loads `/etc/codex/config.toml`. Claude uses Home Manager's `mcpServers` option
without secrets, or its `plugins` option to load a runtime manifest from
`/etc/claude-code` with secrets. Both clients retain writable authentication state.
