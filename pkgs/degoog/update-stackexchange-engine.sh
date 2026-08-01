#!/usr/bin/env bash
set -euo pipefail

attr="${UPDATE_NIX_ATTR_PATH:-degoog-stackexchange-engine}"
system="${UPDATE_NIX_SYSTEM:-x86_64-linux}"
package_file="pkgs/degoog/stackexchange-engine.nix"

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

# Branch mode follows upstream's untagged main branch and writes the commit
# date into the snapshot version. Preserve the extension version declared in
# package.json instead of nix-update's fallback 0 prefix.
nix-update --flake --system "$system" --version branch "$attr"

src_path="$(nix eval --option eval-cache false --raw ".#packages.$system.$attr.src")"
package_version="$(nix eval --option eval-cache false --raw ".#packages.$system.$attr.version")"
upstream_version="$(jq --raw-output '.engines[0].version // empty' "$src_path/package.json")"
snapshot_date="${package_version##*-unstable-}"

if [[ -z "$upstream_version" ]]; then
  echo "failed to read upstream version from $src_path/package.json" >&2
  exit 1
fi
if [[ ! "$snapshot_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
  echo "failed to read snapshot date from package version: $package_version" >&2
  exit 1
fi

sed -i -E \
  's#^  version = "[^"]+";#  version = "'"$upstream_version-unstable-$snapshot_date"'";#' \
  "$package_file"
