#!/usr/bin/env bash
set -euo pipefail

attr="${UPDATE_NIX_ATTR_PATH:-nico-cli}"
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

nix-update --flake --system "$system" --version "$version" "$attr"
