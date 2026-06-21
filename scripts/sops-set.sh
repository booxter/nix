#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/sops-set.sh HOST KEY_PATH
  scripts/sops-set.sh --help

Set KEY_PATH in secrets/HOST.yaml to the exact value read from stdin.
KEY_PATH is slash-separated, for example:
  scripts/sops-set.sh srvarr romm/authSecretKey < secret.txt

Values are read from stdin to avoid putting secrets in shell history or argv.
One trailing newline is stripped, matching command-substitution behavior.
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

path_to_jq_array() {
  local raw="$1"
  local segment
  local -a segments
  local escaped
  local array="["
  local first="1"

  raw="${raw#.}"
  raw="${raw#/}"
  if [[ -z "$raw" ]]; then
    echo "KEY_PATH must not be empty." >&2
    return 1
  fi

  IFS='/' read -r -a segments <<< "$raw"
  for segment in "${segments[@]}"; do
    [[ -z "$segment" ]] && continue
    escaped="${segment//\\/\\\\}"
    escaped="${escaped//\"/\\\"}"
    if [[ "$first" == "1" ]]; then
      first="0"
    else
      array+=","
    fi
    array+="\"${escaped}\""
  done

  array+="]"
  if [[ "$array" == "[]" ]]; then
    echo "KEY_PATH must not be empty." >&2
    return 1
  fi
  printf '%s' "$array"
}

main() {
  local host=""
  local key_path=""

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
        elif [[ -z "$key_path" ]]; then
          key_path="$1"
        else
          usage >&2
          exit 1
        fi
        shift
        ;;
    esac
  done

  if [[ -z "$host" || -z "$key_path" ]]; then
    usage >&2
    exit 1
  fi

  if [[ -t 0 ]]; then
    echo "Refusing to read secret value from terminal; pipe or redirect the value on stdin." >&2
    exit 1
  fi

  local value
  value="$(cat)"

  local key_path_array
  key_path_array="$(path_to_jq_array "$key_path")"

  local repo_root
  repo_root="$(resolve_repo_root)"
  # shellcheck disable=SC1091
  source "${repo_root}/scripts/_helpers/host-aliases.sh"
  host="$(canonical_secret_host "$repo_root" "$host")"

  local secret="${repo_root}/secrets/${host}.yaml"
  if [[ ! -f "$secret" ]]; then
    echo "Secret not found: $secret"
    exit 1
  fi

  local plain
  local updated_json
  local sorted_json
  local encrypted
  plain="$(mktemp)"
  updated_json="$(mktemp)"
  sorted_json="$(mktemp)"
  encrypted="$(mktemp)"
  trap 'rm -f "${plain:-}" "${updated_json:-}" "${sorted_json:-}" "${encrypted:-}"' EXIT

  sops --decrypt "$secret" > "$plain"
  yq -o=json '.' "$plain" \
    | jq --argjson path "$key_path_array" --arg value "$value" 'setpath($path; $value)' \
    > "$updated_json"
  jq -S 'del(.sops)' "$updated_json" > "$sorted_json"
  sops --encrypt --filename-override "$secret" --input-type json --output-type yaml "$sorted_json" > "$encrypted"
  mv "$encrypted" "$secret"

  echo "Updated ${host}:${key_path}."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
