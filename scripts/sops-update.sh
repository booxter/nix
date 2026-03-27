#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/sops-update.sh [HOST]
  scripts/sops-update.sh --help

Update secrets/HOST.yaml from template defaults in secrets/_template.yaml and,
if present, secrets/_templates/HOST.yaml.

If HOST is omitted, the current short hostname is used.
Template keys are added only if missing; existing values win.
EOF
}

resolve_repo_root() {
  if git -C "$PWD" rev-parse --show-toplevel >/dev/null 2>&1; then
    git -C "$PWD" rev-parse --show-toplevel
    return
  fi
  local script_dir
  script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
  cd -- "${script_dir}/.." && pwd
}

main() {
  host=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h | --help)
        usage
        exit 0
        ;;
      -*)
        echo "Unknown option: $1" >&2
        usage >&2
        exit 1
        ;;
      *)
        if [[ -z "$host" ]]; then
          host="$1"
          shift
        else
          usage
          exit 1
        fi
        ;;
    esac
  done

  if [[ -z "$host" ]]; then
    host="$(hostname -s)"
  fi

  local repo_root
  repo_root="$(resolve_repo_root)"
  template="${repo_root}/secrets/_template.yaml"
  host_template="${repo_root}/secrets/_templates/${host}.yaml"
  secret="${repo_root}/secrets/${host}.yaml"

  if [[ ! -f "$template" ]]; then
    echo "Template not found: $template"
    exit 1
  fi

  if [[ ! -f "$secret" ]]; then
    echo "Secret not found: $secret"
    exit 1
  fi

  tmp="$(mktemp)"
  base="$(mktemp)"
  merged="$(mktemp)"
  sorted="$(mktemp)"
  encrypted="$(mktemp)"

  trap 'rm -f "$tmp" "$base" "$merged" "$sorted" "$encrypted"' EXIT

  sops --decrypt "$secret" > "$tmp"
  cp "$template" "$base"
  if [[ -f "$host_template" ]]; then
    yq -s '.[0] * .[1]' "$base" "$host_template" > "$merged"
    mv "$merged" "$base"
  fi
  yq -s '.[0] * .[1]' "$base" "$tmp" > "$merged"
  # shellcheck disable=SC2016
  yq '
    (.sops // null) as $sops
    | del(.sops)
    | sort_keys(..)
    | if $sops == null then . else . + {"sops": $sops} end
  ' "$merged" > "$sorted"
  sops --encrypt --filename-override "$secret" --input-type yaml --output-type yaml "$sorted" > "$encrypted"
  mv "$encrypted" "$secret"

  echo "Updated secret from templates: $secret"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
