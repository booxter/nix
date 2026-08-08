#!/usr/bin/env bash
# shellcheck shell=bash

set -euo pipefail

cd -- "$(git rev-parse --show-toplevel)"

deadnix --edit .
treefmt --tree-root "$PWD" .
git ls-files -z -- '*Cargo.toml' |
  xargs -0 -r -n 1 cargo fmt --all --manifest-path
deadnix --fail .
mbake format --config ./fmt/bake.toml Makefile
while IFS= read -r -d '' file; do
  tmp=$(mktemp)
  trap 'rm -f "$tmp"' EXIT
  jq -S --indent 2 . "$file" > "$tmp"
  chmod --reference="$file" "$tmp" 2>/dev/null || true
  chown --reference="$file" "$tmp" 2>/dev/null || true
  mv "$tmp" "$file"
  trap - EXIT
done < <(git ls-files -z -- '*.json')
actionlint .github/workflows/*.yml

declare -A tracked_formatters=(
  ["*.sh"]="shellcheck"
  ["*.yaml *.yml :(exclude)secrets/*/*.yaml"]="prettier --write --log-level warn"
  ["*.md"]="markdownlint-cli2"
  ["*.py"]=$'ruff format\nruff check'
  ["*.js"]="eslint --no-config-lookup --config ./fmt/eslint.config.js"
)

for pathspec in "${!tracked_formatters[@]}"; do
  read -r -a pathspec_args <<< "$pathspec"
  while IFS= read -r formatter; do
    read -r -a formatter_args <<< "$formatter"
    git ls-files -z -- "${pathspec_args[@]}" |
      xargs -0 -r "${formatter_args[@]}"
  done <<< "${tracked_formatters[$pathspec]}"
done
