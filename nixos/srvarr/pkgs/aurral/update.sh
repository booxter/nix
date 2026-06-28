#!/usr/bin/env bash
set -euo pipefail

attr="${UPDATE_NIX_ATTR_PATH:-aurral}"
system="${UPDATE_NIX_SYSTEM:-x86_64-linux}"
package_file="nixos/srvarr/pkgs/aurral/default.nix"

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

if [[ ! -f "$package_file" ]]; then
  echo "aurral package file not found: $package_file" >&2
  exit 1
fi

nix-update --flake --system "$system" --src-only --use-github-releases "$attr"

src_path="$(nix eval --option eval-cache false --raw ".#packages.$system.$attr.src")"
npm_deps_hash="$(NPM_FETCHER_VERSION=2 prefetch-npm-deps "$src_path/package-lock.json" | tail -n 1)"
if [[ ! "$npm_deps_hash" =~ ^sha256- ]]; then
  echo "failed to prefetch npm dependencies for $attr: $npm_deps_hash" >&2
  exit 1
fi

sed -i -E \
  's#(npmDepsHash = ")[^"]+(";)#\1'"$npm_deps_hash"'\2#' \
  "$package_file"
