# shellcheck shell=bash
treefmt "$@"
mbake format --config ./.bake.toml Makefile
git ls-files -z -- '*.sh' '**/*.sh' | xargs -0 -r shellcheck
while IFS= read -r -d '' file; do
  tmp=$(mktemp)
  trap 'rm -f "$tmp"' EXIT
  jq -S --indent 2 . "$file" > "$tmp"
  chmod --reference="$file" "$tmp" 2>/dev/null || true
  chown --reference="$file" "$tmp" 2>/dev/null || true
  mv "$tmp" "$file"
  trap - EXIT
done < <(git ls-files -z -- '*.json' '**/*.json')
actionlint .github/workflows/*.yml
git ls-files -z -- '*.md' '**/*.md' | xargs -0 -r markdownlint-cli2
git ls-files -z -- '*.py' '**/*.py' | xargs -0 -r ruff format
git ls-files -z -- '*.py' '**/*.py' | xargs -0 -r ruff check
git ls-files -z -- '*.js' '**/*.js' | xargs -0 -r eslint \
  --no-config-lookup \
  --config ./eslint.config.js
