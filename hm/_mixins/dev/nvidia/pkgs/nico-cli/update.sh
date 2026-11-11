#!/usr/bin/env bash
set -euo pipefail

attr="${UPDATE_NIX_ATTR_PATH:-updatePackages.x86_64-linux.nico-cli}"
system="${UPDATE_NIX_SYSTEM:-x86_64-linux}"
repo_url="https://github.com/NVIDIA/infra-controller.git"

version="$(
  git ls-remote --tags --refs "$repo_url" |
    sed -nE \
      -e 's@.*refs/tags/v2\.([0-9]+)\.([0-9]+)$@\1 \2 1 0 2.\1.\2@p' \
      -e 's@.*refs/tags/v2\.([0-9]+)\.([0-9]+)-rc\.([0-9]+)$@\1 \2 0 \3 2.\1.\2-rc.\3@p' |
    sort -n -k1,1 -k2,2 -k3,3 -k4,4 |
    tail -n 1 |
    cut -d' ' -f5
)"

if [[ -z "$version" ]]; then
  echo "no matching v2.x.y or v2.x.y-rc.N tags found" >&2
  exit 1
fi

current_rev="$(nix eval --raw ".#${attr}.src.rev")"
next_rev="v${version}"

if [[ "$current_rev" == "$next_rev" ]]; then
  exit 0
fi

checkout="$(mktemp -d)"
trap 'rm -rf "$checkout"' EXIT

git init --bare --quiet "$checkout"
git -C "$checkout" fetch --quiet --depth=1 --filter=blob:none "$repo_url" \
  "refs/tags/${current_rev}:refs/tags/${current_rev}" \
  "refs/tags/${next_rev}:refs/tags/${next_rev}"

# Compare subtree contents across releases, including any previously skipped tags.
current_tree="$(git -C "$checkout" rev-parse "${current_rev}:rest-api/cli")"
next_tree="$(git -C "$checkout" rev-parse "${next_rev}:rest-api/cli")"

if [[ "$current_tree" == "$next_tree" ]]; then
  echo "Skipping $next_rev: rest-api/cli is unchanged since $current_rev"
  exit 0
fi

nix-update --flake --system "$system" --version "$version" "$attr"
