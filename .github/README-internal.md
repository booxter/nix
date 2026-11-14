# CI

The [build workflow](workflows/build-targets.yml) checks formatting, runs tests,
and builds the full fleet. `ci-success` is the required merge gate.

- Configuration diffs are advisory and compare the base with the merge result
  that CI built.
- Runner hosts also serve interactive users. Linux jobs have an isolated
  filesystem; workspaces are disposable, but Nix caches persist between jobs.
- Only outputs selected by CI build and check jobs go to the public Attic cache.
  Other builds publish only internally.
- Scheduled flake update PRs changing only `flake.lock` may auto-merge when
  configuration diffs are available and show no package or generated config
  changes. Size-only changes do not prevent auto-merge.
