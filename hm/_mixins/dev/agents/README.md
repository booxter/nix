# Coding agents

Codex and Claude Code share `context.md`, `skills/`, and
`host.hm.dev.agents.mcp` server declarations. Their packages come from unstable;
Claude is enabled in the NVIDIA developer profile through `programs.claude-code`.

`orchestration.nix` supplies a shared delegation policy, parameterized by each
client's `models` mapping. Codex uses Sol / Terra / Astra; Claude uses
Opus / Sonnet / Fable for default work, bounded implementation, and specialist
analysis respectively. The default also selects the main session model.
Delegation uses explicit runtime model selection, with at most two workers,
no nested delegation, and integration and commits owned by the lead.
Codex model IDs are centralized in its mapping; update them when adopting a new
generation. Claude uses its rolling family aliases. Codex V2 enforces the worker
limit but leaves the no-nesting rule to the prompt.

The Codex launcher explicitly selects the preferred
model and high effort when the model catalog lists it, overriding workspace
defaults. Unavailable models or failed lookups use normal configuration instead.
Explicit model, profile, or configuration options pass through. Codex handles
the preferred defaults for each subcommand.

MCP URLs, header values, and values in `oauth.clientIds` accept strings or
`{ secret = "sops/key"; }`. OAuth client IDs are keyed by `codex` or `claude`
because each application has its own registered callbacks. Shared `instructions`
are appended to both clients' context; `startupTimeoutSec` only maps to Codex.

`common/_mixins/agents` renders secret-backed configuration with SOPS. Codex
loads `/etc/codex/config.toml`. Claude uses Home Manager's `mcpServers` option
without secrets, or loads a runtime plugin from `/etc/claude-code` with
secrets. Both clients retain writable authentication state.

Home Manager reapplies declared Claude settings and preserves undeclared keys,
including the model chosen in Claude.
