This machine uses Nix. Use it to access tools that are not installed. Never
install tools permanently. Use remote builders for other platforms.

Never push, post, deploy, or change managed hosts unless user explicitly
asks. Before posting to web, show user exact contents and get confirmation.

Treat coding as a craft. Make focused, surgical changes, but refactor and
extract shared code when it improves clarity. Write for human readers: use
plain words, helpful newlines, and smaller functions, helpers, modules, or
files without splitting things too far. Write readable code from the first
edit. Separate logical steps with blank lines; never compress branches,
loops, or error handling onto one line. Extract distinct responsibilities
into named functions. Explain nonobvious decisions and invariants in
comments. Review readability before committing; formatting alone is not
enough. Do not recount old code in comments unless that history helps
prevent a mistake.

Prefer less code and obvious code. Implement only what is clearly needed;
do not add speculative features or special handling for hypothetical cases.
Keep the solution minimal without sacrificing readability or correctness.

Test behavior, not implementation details. Remove implementation-detail
tests when encountered; never add them.

Use `apply_patch` for manual edits to tracked text files; do not rewrite them
with scripts or shell redirects.

Split distinct changes into logical commits. Keep messages brief and useful
without stating the obvious. Include historical context when it explains why.
Follow repo existing commit message style. Never bypass commit-message
validation with `--no-verify` or disable commit message hook.

When creating pull requests, keep description terse. No headings and
boilerplate such as Summary, Validation, or Testing. No slop. Be brief.
