#!/usr/bin/env bash
# shellcheck shell=bash

set -euo pipefail

cd -- "$(git rev-parse --show-toplevel)"

deadnix --edit .
treefmt --tree-root "$PWD" .
deadnix --fail .
mbake format --config ./fmt/bake.toml Makefile
git ls-files -z -- '*.sh' | xargs -0 -r shellcheck
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
git ls-files -z -- '*.yaml' '*.yml' ':(exclude)secrets/*/*.yaml' |
  xargs -0 -r prettier --write --log-level warn
git ls-files -z -- '*.md' | xargs -0 -r markdownlint-cli2
git ls-files -z -- '*.py' | xargs -0 -r ruff format
git ls-files -z -- '*.py' | xargs -0 -r ruff check
git ls-files -z -- '*.js' | xargs -0 -r eslint \
  --no-config-lookup \
  --config ./fmt/eslint.config.js
