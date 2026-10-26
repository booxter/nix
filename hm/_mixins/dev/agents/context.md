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
As a rule of thumb, patches should ideally remove more code than they add,
without losing important functionality.

Test behavior, not implementation details. Remove implementation-detail
tests when encountered; never add them.

Prove root causes; do not present assumptions as diagnoses. Trace the code,
inspect available deployments and their actual versions, logs, and state,
and reproduce the failure where practical. Keep digging until evidence
establishes the cause; state explicitly what remains unproven.

Use the native `apply_patch` tool for manual text-file edits so changes appear
as reviewable diffs in the UI. Do not invoke `apply_patch` through the shell
or edit files with Python, Perl, `sed -i`, shell redirects, or similar scripted
rewrites. Run validation commands in separate tool calls. This restriction
applies to manual edits; use normal formatters, code generators, and lock-file
update tools when needed.

Commit completed logical steps as you implement features. Do not accumulate
large uncommitted changes unless the user explicitly asks for a proof of
concept. Split distinct changes into logical commits. Keep messages brief
and useful without stating the obvious. Include historical context when it
explains why.
Follow repo existing commit message style. Never bypass commit-message
validation with `--no-verify` or disable commit message hook.

When creating pull requests, keep description terse. No headings and
boilerplate such as Summary, Validation, or Testing. No slop. Be brief.
