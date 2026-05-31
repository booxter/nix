# GitHub CI Behavior

This repository uses `.github/workflows/build-targets.yml` to run CI.

## High-level flow

For pull requests, CI runs:

1. `plan-build-matrix` to determine change scope.
2. `format` always.
3. Heavy jobs only when not docs-only:
   - `get-hosts-check`
   - `build` matrix (scoped dynamically)
4. `ci-success` as the required final gate.

## Dynamic matrix rules (pull requests)

The build matrix is selected in this order:

1. **Docs-only PR** (`README.md`, `docs/**`, or any `*.md` file only):
   - Skip heavy jobs (`get-hosts-check`, `flake-check`, `build`).
2. **Darwin-only PR** (all changed files under `darwin/**`):
   - Run only macOS build jobs.
3. **NixOS-only PR** (all changed files under `nixos/**`):
   - Run only Linux build jobs.
4. **Machine-specific PR** (all changed files match known machine prefixes):
   - Run only mapped jobs for those machines.
   - Includes host secrets files under `secrets/<host>.yaml` and
     `secrets/_templates/<host>.yaml` for mapped hosts.
5. **Fallback**:
   - Run full build matrix.

## Notes

- `format` runs `nix fmt .`, which uses the flake-pinned formatter and includes
  workflow (`actionlint`) and markdown checks.
- `push` and `workflow_dispatch` use full matrix behavior (docs-only shortcut is
  PR-only).
- If no machine-specific mapping applies cleanly, CI falls back to full scoped matrix.

## Flake update diffs

`.github/workflows/flake-update-diffs.yml` runs only for same-repository
`ci/flake-update` pull requests that change `flake.lock`.

It runs `nix run .#diff -- --details <machine> <base-sha> <head-sha>` in a separate
advisory matrix for each toplevel NixOS and nix-darwin machine in
`ci-target-inventory.json`. Each matrix job uploads one markdown artifact, and
the final job replaces the marked `Config diffs` section in the PR body. The
marker replacement keeps reruns idempotent and avoids duplicating the machine
list.
