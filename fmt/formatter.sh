#!/usr/bin/env bash
# shellcheck shell=bash

set -euo pipefail

cd -- "$(git rev-parse --show-toplevel)"

# Apply the broad formatters before running file-specific checks.
deadnix --edit .
treefmt --tree-root "$PWD" .
deadnix --fail .

mbake format --config ./fmt/bake.toml Makefile

git ls-files -z -- '*.sh' | xargs -0 -r shellcheck

# Sort JSON keys without changing file ownership or permissions.
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

# Encrypted secret files should not be rewritten by Prettier.
git ls-files -z -- '*.yaml' '*.yml' ':(exclude)secrets/*/*.yaml' |
  xargs -0 -r prettier --write --log-level warn

# Codex context is prompt text without a heading; keep MD041 on elsewhere.
markdown_lint_excludes=(
  hm/_mixins/dev/agents/codex/context.md
)
markdown_lint_exclude_pathspecs=()
for file in "${markdown_lint_excludes[@]}"; do
  markdown_lint_exclude_pathspecs+=(":(exclude)$file")
done

git ls-files -z -- '*.md' "${markdown_lint_exclude_pathspecs[@]}" |
  xargs -0 -r markdownlint-cli2

markdownlint-cli2 --config ./fmt/codex-context.markdownlint.json \
  "${markdown_lint_excludes[@]}"

git ls-files -z -- '*.py' | xargs -0 -r ruff format --config ./ruff.toml
git ls-files -z -- '*.py' | xargs -0 -r ruff check --config ./ruff.toml

git ls-files -z -- '*.js' | xargs -0 -r eslint \
  --no-config-lookup \
  --config ./fmt/eslint.config.js
