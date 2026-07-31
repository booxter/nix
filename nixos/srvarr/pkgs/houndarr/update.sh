#!/usr/bin/env bash
set -euo pipefail

attr="${UPDATE_NIX_ATTR_PATH:-houndarr}"
system="${UPDATE_NIX_SYSTEM:-x86_64-linux}"

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

# nix-update updates the tagged source and all fixed-output hashes, including
# the pnpm dependency cache produced from the release lock file.
nix-update --flake --system "$system" --use-github-releases "$attr"
