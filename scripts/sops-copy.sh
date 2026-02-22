#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/sops-copy.sh SRC_HOST DST_HOST KEY_PATH

Copy KEY_PATH from secrets/SRC_HOST.yaml into secrets/DST_HOST.yaml.
Example:
  scripts/sops-copy.sh mair prx1-lab attic
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

path_to_yq_expr() {
  local raw="$1"
  local expr
  local segment
  local escaped

  raw="${raw#.}"
  raw="${raw#/}"
  if [[ -z "$raw" ]]; then
    echo "KEY_PATH must not be empty."
    return 1
  fi

  expr=""
  while IFS='/' read -r segment || [[ -n "$segment" ]]; do
    [[ -z "$segment" ]] && continue
    escaped="${segment//\\/\\\\}"
    escaped="${escaped//\"/\\\"}"
    expr="${expr}.\"${escaped}\""
  done <<< "$raw"

  if [[ -z "$expr" ]]; then
    echo "KEY_PATH must not be empty."
    return 1
  fi

  printf '%s' "$expr"
}

path_to_jq_array() {
  local raw="$1"
  local segment
  local escaped
  local array="["
  local first="1"

  raw="${raw#.}"
  raw="${raw#/}"
  if [[ -z "$raw" ]]; then
    echo "KEY_PATH must not be empty."
    return 1
  fi

  while IFS='/' read -r segment || [[ -n "$segment" ]]; do
    [[ -z "$segment" ]] && continue
    escaped="${segment//\\/\\\\}"
    escaped="${escaped//\"/\\\"}"
    if [[ "$first" == "1" ]]; then
      first="0"
    else
      array+=","
    fi
    array+="\"${escaped}\""
  done <<< "$raw"

  array+="]"
  if [[ "$array" == "[]" ]]; then
    echo "KEY_PATH must not be empty."
    return 1
  fi
  printf '%s' "$array"
}

main() {
  if [[ $# -ne 3 ]]; then
    usage
    exit 1
  fi

  local src_host="$1"
  local dst_host="$2"
  local key_path="$3"
  local key_expr
  local key_path_array
  key_expr="$(path_to_yq_expr "$key_path")"
  key_path_array="$(path_to_jq_array "$key_path")"

  local repo_root
  repo_root="$(resolve_repo_root)"

  local src_secret="${repo_root}/secrets/${src_host}.yaml"
  local dst_secret="${repo_root}/secrets/${dst_host}.yaml"

  if [[ ! -f "$src_secret" ]]; then
    echo "Source secret not found: $src_secret"
    exit 1
  fi
  if [[ ! -f "$dst_secret" ]]; then
    echo "Destination secret not found: $dst_secret"
    exit 1
  fi

  local src_plain
  local dst_plain
  local merged_plain
  local encrypted
  src_plain="$(mktemp)"
  dst_plain="$(mktemp)"
  merged_plain="$(mktemp)"
  encrypted="$(mktemp)"
  trap 'rm -f "${src_plain:-}" "${dst_plain:-}" "${merged_plain:-}" "${encrypted:-}"' EXIT

  sops --decrypt "$src_secret" > "$src_plain"
  sops --decrypt "$dst_secret" > "$dst_plain"

  if ! yq -e "${key_expr} != null" "$src_plain" >/dev/null; then
    echo "Path not found in source secret: $key_path"
    exit 1
  fi

  yq -y -s "(.[0] | getpath(${key_path_array})) as \$v | .[1] | setpath(${key_path_array}; \$v)" \
    "$src_plain" "$dst_plain" > "$merged_plain"

  sops --encrypt --filename-override "$dst_secret" --input-type yaml --output-type yaml "$merged_plain" > "$encrypted"
  mv "$encrypted" "$dst_secret"

  echo "Copied ${key_path} from ${src_host} to ${dst_host}."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
