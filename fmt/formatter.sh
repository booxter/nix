#!/usr/bin/env bash
# shellcheck shell=bash

set -euo pipefail

cd -- "$(git rev-parse --show-toplevel)"

git ls-files -z -- '*Cargo.toml' |
  xargs -0 -r -n 1 cargo fmt --all --manifest-path
actionlint .github/workflows/*.yml

fmt_nix() {
  deadnix --edit "$@"
  treefmt --tree-root "$PWD" "$@"
  deadnix --fail "$@"
}

fmt_makefile() {
  mbake format --config ./fmt/bake.toml "$@"
}

fmt_json() {
  local file formatted
  for file in "$@"; do
    formatted=$(jq -S --indent 2 . "$file")
    printf '%s\n' "$formatted" > "$file"
  done
}

fmt_shell() {
  shellcheck "$@"
}

fmt_yaml() {
  prettier --write --log-level warn "$@"
}

fmt_markdown() {
  markdownlint-cli2 "$@"
}

fmt_python() {
  ruff format "$@"
  ruff check "$@"
}

fmt_javascript() {
  eslint --no-config-lookup --config ./fmt/eslint.config.js "$@"
}

declare -A tracked_formats=(
  ["nix"]="*.nix"
  ["makefile"]="Makefile"
  ["json"]="*.json"
  ["shell"]="*.sh"
  ["yaml"]="*.yaml *.yml :(exclude)secrets/*/*.yaml"
  ["markdown"]="*.md"
  ["python"]="*.py"
  ["javascript"]="*.js"
)

for format in "${!tracked_formats[@]}"; do
  pathspec=${tracked_formats[$format]}
  read -r -a pathspec_args <<< "$pathspec"
  mapfile -d '' -t files < <(git ls-files -z -- "${pathspec_args[@]}")
  if ((${#files[@]} == 0)); then
    continue
  fi
  "fmt_${format}" "${files[@]}"
done
