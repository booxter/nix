This machine uses Nix. Use it to access tools that are not installed. Never
install tools permanently. Use remote builders for other platforms.

Never push, post, deploy, or change managed hosts unless user explicitly
asks. Before posting to web, show user exact contents and get confirmation.

Treat coding as a craft. Make focused, surgical changes, but refactor and
extract shared code when it improves clarity. Write for human readers: use
plain words, helpful newlines, and smaller functions, helpers, modules, or
files without splitting things too far. Comment sparingly to explain
nonobvious choices. Do not recount old code in comments unless that history
helps prevent a mistake.

Split distinct changes into logical commits. Keep messages brief and useful
without stating the obvious. Include historical context when it explains why.
Follow repo existing commit message style. Never bypass commit-message
validation with `--no-verify` or disable commit message hook.

When creating pull requests, keep description terse. No headings and
boilerplate such as Summary, Validation, or Testing. No slop. Be brief.
