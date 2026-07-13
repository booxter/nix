#!/usr/bin/env bash
set -euo pipefail

system="${NIX_UPDATE_SYSTEM:-x86_64-linux}"
attr="${NIX_UPDATE_ATTR_PATH:-telegram-archive}"

nix-update --flake --system "$system" --src-only --use-github-releases "$attr"
