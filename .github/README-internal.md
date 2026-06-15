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

## Config diffs

Pull request build jobs that target a toplevel NixOS or nix-darwin machine also
run `nix run .#diff -- --details <machine> <base-sha> <head-sha>` after the
blocking `nix build`. Diff generation is advisory: failures are captured in the
uploaded artifact and PR comment, but the build job result is still determined
by the blocking build.

Pull request jobs explicitly check out GitHub's generated merge ref
(`refs/pull/<number>/merge`). The diff head is the checked-out merge commit, not
the raw PR branch tip, so diffs reflect the revision CI built after applying the
PR to the current base branch.

The build matrix selection controls which machines get diffs. Machine-specific
PRs only diff the selected machine jobs, while scoped or full matrix PRs diff
the toplevel machine jobs included in that matrix. VM, QEMU, ISO, and other
non-toplevel targets remain build-only.

The PR comment groups diff results into machines with package or generated
config changes, machines with closure-size-only changes, and machines with no
changes.
Per-machine artifacts are prefixed with `package-or-config-`, `size-only-`, or
`unchanged-`; the post job uses those prefixes when assembling the grouped
comment.
