#!/usr/bin/env bash
set -euo pipefail

attr="${UPDATE_NIX_ATTR_PATH:-updatePackages.x86_64-linux.degoog-official-extensions}"
system="${UPDATE_NIX_SYSTEM:-x86_64-linux}"

nix-update --flake --system "$system" --version branch "$attr"
