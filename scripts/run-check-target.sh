#!/usr/bin/env bash
# shellcheck shell=bash

set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "Usage: $0 <flake-attr> <label-plural> <label-singular>" >&2
  exit 64
fi

flake_attr="$1"
label_plural="$2"
label_singular="$3"
what="${WHAT:-}"
remote="${REMOTE:-true}"

builder_opts=()
if [ "$remote" = "false" ]; then
  local_builders="$(nix run --quiet --option builders '' .#get-local-builders -- --local)"
  builder_opts=(--option builders "$local_builders")
fi

nom_build() {
  local attr="$1"

  nix shell "${builder_opts[@]}" --inputs-from . nixpkgs#nix-output-monitor \
    -c nom build "${builder_opts[@]}" "$attr" -L --show-trace
}

system="$(nix eval --impure --raw --expr builtins.currentSystem)"
linux_system="$system"
case "$system" in
*-darwin) linux_system="${system%-darwin}-linux" ;;
esac

check_system="$system"
if [ "$flake_attr" = "nixosTests" ]; then
  check_system="$linux_system"
fi

checks="$(nix eval --json ".#$flake_attr.$check_system" --apply builtins.attrNames | jq -r '.[]')"

if [ -z "$what" ]; then
  if [ -z "$checks" ]; then
    echo "No $label_plural for $check_system."
    exit 0
  fi

  while IFS= read -r check_name; do
    echo "Running $check_name on $check_system..."
    nom_build ".#$flake_attr.$check_system.$check_name"
  done <<<"$checks"
  exit 0
fi

if ! printf '%s\n' "$checks" | grep -Fxq "$what"; then
  echo "Unknown $label_singular: $what"
  echo
  echo "Available $label_plural for $check_system:"
  printf '%s\n' "$checks"

  if [ "$flake_attr" = "checks" ]; then
    nixos_checks="$(nix eval --json ".#nixosTests.$linux_system" --apply builtins.attrNames | jq -r '.[]')"
    if printf '%s\n' "$nixos_checks" | grep -Fxq "$what"; then
      echo
      echo "Hint: use make check-nixos WHAT=$what"
    fi
  fi

  exit 1
fi

nom_build ".#$flake_attr.$check_system.$what"
