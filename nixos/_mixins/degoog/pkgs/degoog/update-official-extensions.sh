#!/usr/bin/env bash
set -euo pipefail

attr="${UPDATE_NIX_ATTR_PATH:-updatePackages.x86_64-linux.degoog-official-extensions}"
package_file="nixos/_mixins/degoog/pkgs/degoog/official-extensions.nix"
repo_url="https://github.com/degoog-org/official-extensions.git"

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

prefetched="$(nix-prefetch-git --quiet "$repo_url" refs/heads/main)"
rev="$(jq --exit-status --raw-output .rev <<< "$prefetched")"
hash="$(jq --exit-status --raw-output .hash <<< "$prefetched")"
snapshot_date="$(jq --exit-status --raw-output '.date | split("T")[0]' <<< "$prefetched")"

if [[ ! "$rev" =~ ^[0-9a-f]{40}$ ]]; then
  echo "failed to read revision for $attr: $rev" >&2
  exit 1
fi
if [[ ! "$hash" =~ ^sha256- ]]; then
  echo "failed to prefetch source for $attr: $hash" >&2
  exit 1
fi
if [[ ! "$snapshot_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
  echo "failed to read snapshot date for $attr: $snapshot_date" >&2
  exit 1
fi

sed -i -E \
  -e 's#^  rev = "[0-9a-f]{40}";#  rev = "'"$rev"'";#' \
  -e 's#^    hash = "sha256-[^"]+";#    hash = "'"$hash"'";#' \
  -e 's#^  version = "0-unstable-[0-9]{4}-[0-9]{2}-[0-9]{2}";#  version = "0-unstable-'"$snapshot_date"'";#' \
  "$package_file"
