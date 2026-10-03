# GitHub CI Behavior

This repository uses `.github/workflows/build-targets.yml` to run CI.

## High-level flow

For pull requests, CI runs:

1. `format` checks formatting and evaluates the build and check inventories.
2. `codex` prebuilds Codex for Linux and macOS.
3. `check_batch` builds non-NixOS checks once per system, while `nixos_test`
   runs each NixOS test as a separate job with bounded parallelism.
4. `build` runs every fleet build target in the matrix.
5. `post-config-diffs` publishes advisory machine configuration diffs.
6. `ci-success` serves as the required final gate.

## Notes

- `format` runs `nix fmt .`, which uses the flake-pinned formatter and includes
  workflow (`actionlint`) and markdown checks.
- Pull requests, pushes, and manual runs all use the full build matrix.

## Runners

The `ci` host provides six ephemeral `nix-ci` runners. It does not build
locally; Nix delegates Linux builds to the builder hosts and macOS builds to
`mmini`. The `mmini-ci` service provides the `nix-ci-darwin` label for checks
and update jobs that must execute on macOS.

Completed CI builds are published to both the private `default` Attic cache
and the public `github` cache. Other managed hosts publish only to their
realm's default cache.

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

Every toplevel NixOS and nix-darwin machine job generates a diff. VM, QEMU,
ISO, and other non-toplevel targets remain build-only.

The PR comment groups diff results into machines with package or generated
config changes, machines with closure-size-only or dix path/size-only
changes, and machines with no changes.
Per-machine artifacts are prefixed with `package-or-config-`, `size-only-`, or
`unchanged-`; the post job uses those prefixes when assembling the grouped
comment.
Before posting a new config diff comment batch, the post job marks earlier
bot-authored config diff comments on the same pull request as outdated.
Flake input update pull requests list every changed input in a table with its old
and new revisions and a link to the upstream comparison. Nested inputs use their
full lock path, while `follows` aliases are omitted.
The generator and its tests are packaged as
`nix run .#flake-input-update-summary`.
For scheduled flake input update PRs, if at least one target produced a config
diff artifact and no package-or-config entries were found, the post job
enables GitHub auto-merge for the pull request. The PR must come from
`ci/flake-update`, have title `flake: update inputs`, include the scheduled
trigger marker in its body, and change only `flake.lock`. Closure-size-only,
dix path/size-only, and unchanged diffs are considered safe for this auto-merge
path.
