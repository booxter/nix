#!/usr/bin/env bash
set -euo pipefail

attr="${UPDATE_NIX_ATTR_PATH:-ebook-converter-cli}"
system="${UPDATE_NIX_SYSTEM:-x86_64-linux}"
package_file="nixos/srvarr/pkgs/ebook-converter-cli/default.nix"

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

# Branch mode follows upstream's untagged master branch and writes the commit
# date into the snapshot version. Preserve the version declared by upstream's
# pyproject instead of nix-update's fallback 0 prefix for release-less repos.
nix-update --flake --system "$system" --version branch "$attr"

src_path="$(nix eval --option eval-cache false --raw ".#packages.$system.$attr.src")"
package_version="$(nix eval --option eval-cache false --raw ".#packages.$system.$attr.version")"
upstream_version="$(sed -n -E 's/^version = "([^"]+)".*/\1/p' "$src_path/pyproject.toml")"
snapshot_date="${package_version##*-unstable-}"

if [[ -z "$upstream_version" ]]; then
  echo "failed to read upstream version from $src_path/pyproject.toml" >&2
  exit 1
fi
if [[ ! "$snapshot_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
  echo "failed to read snapshot date from package version: $package_version" >&2
  exit 1
fi

sed -i -E \
  's#^  version = "[^"]+";#  version = "'"$upstream_version-unstable-$snapshot_date"'";#' \
  "$package_file"
