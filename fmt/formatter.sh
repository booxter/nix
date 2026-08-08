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
  ["*.sh"]="shell"
  ["*.yaml *.yml :(exclude)secrets/*/*.yaml"]="yaml"
  ["*.md"]="markdown"
  ["*.py"]="python"
  ["*.js"]="javascript"
)

for pathspec in "${!tracked_formats[@]}"; do
  read -r -a pathspec_args <<< "$pathspec"
  mapfile -d '' -t files < <(git ls-files -z -- "${pathspec_args[@]}")
  if ((${#files[@]} == 0)); then
    continue
  fi
  format=${tracked_formats[$pathspec]}
  "fmt_${format}" "${files[@]}"
done
