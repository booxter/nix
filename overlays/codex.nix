{ codex }:
codex.overrideAttrs (old: {
  patches = (old.patches or [ ]) ++ [
    # https://github.com/openai/codex/issues/47390
    ../patches/codex-show-full-patches.patch
    # Include the current token count alongside the context percentage.
    ../patches/codex-context-tokens.patch
    # Show current-turn tokens beside the working timer and completion metadata.
    ../patches/codex-turn-tokens.patch
    # Retry capacity errors without server advice within the existing retry budget.
    ../patches/codex-capacity-retry.patch
    # Allow ten stream retries by default.
    ../patches/codex-stream-retry-limit.patch
    # Name checkout directories with /worktree <name>; keep managed hash buckets.
    # https://github.com/openai/codex/issues/38326
    ../patches/codex-named-worktrees.patch
  ];
})
