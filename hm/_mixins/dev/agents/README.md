# Coding agents

Codex and Claude Code share `context.md`, `skills/`, and
`host.hm.dev.agents.mcp` server declarations. Their packages come from unstable;
Claude is enabled in the NVIDIA developer profile through `programs.claude-code`.

MCP URLs and values in `oauth.clientIds` accept strings or
`{ secret = "sops/key"; }`. OAuth client IDs are keyed by `codex` or `claude`
because each application has its own registered callbacks. Shared `instructions`
are appended to both clients' context; `startupTimeoutSec` only maps to Codex.

`common/_mixins/agents` renders secret-backed configuration with SOPS. Codex
loads `/etc/codex/config.toml`. Claude uses Home Manager's `mcpServers` option
without secrets, or its `plugins` option to load a runtime manifest from
`/etc/claude-code` with secrets. Both clients retain writable authentication state.

`claude/mutable-settings.nix` backports Home Manager's mutable settings option.
Activation reapplies declared keys and preserves undeclared keys, including the
model chosen in Claude. Remove the extension when the Home Manager pin provides
it.
