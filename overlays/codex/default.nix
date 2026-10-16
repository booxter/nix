{ codex }:
codex.overrideAttrs (old: {
  patches = (old.patches or [ ]) ++ [
    # https://github.com/openai/codex/issues/47390
    ../../patches/codex-show-full-patches.patch
  ];
})
