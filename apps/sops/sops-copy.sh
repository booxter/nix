#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  apps/sops/sops-copy.sh [--domain DOMAIN] SRC_HOST DST_HOST SRC_KEY_PATH [DST_KEY_PATH]
  apps/sops/sops-copy.sh --help

Copy SRC_KEY_PATH between host files in secrets/DOMAIN/.
If DST_KEY_PATH is omitted, SRC_KEY_PATH is used in the destination too.
Example:
  apps/sops/sops-copy.sh mair prx1-lab attic
  apps/sops/sops-copy.sh prx1-lab gw nut/users/upsslave/password nut/monitors/prx1-lab/password
EOF
}

resolve_repo_root() {
  if git -C "$PWD" rev-parse --show-toplevel >/dev/null 2>&1; then
    git -C "$PWD" rev-parse --show-toplevel
    return
  fi
  local script_dir
  script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
  cd -- "${script_dir}/../.." && pwd
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
    echo "KEY_PATH must not be empty."
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
    echo "KEY_PATH must not be empty."
    return 1
  fi
  printf '%s' "$array"
}

json_string() {
  jq -cn --arg value "$1" '$value'
}

path_to_sops_index() {
  local raw="$1"
  local segment
  local -a segments
  local quoted
  local index=""

  raw="${raw#.}"
  raw="${raw#/}"
  if [[ -z "$raw" ]]; then
    echo "KEY_PATH must not be empty."
    return 1
  fi

  IFS='/' read -r -a segments <<< "$raw"
  for segment in "${segments[@]}"; do
    [[ -z "$segment" ]] && continue
    quoted="$(json_string "$segment")"
    index+="[${quoted}]"
  done

  if [[ -z "$index" ]]; then
    echo "KEY_PATH must not be empty."
    return 1
  fi
  printf '%s' "$index"
}

main() {
  local src_host=""
  local dst_host=""
  local src_key_path=""
  local dst_key_path=""
  local domain=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h | --help)
        usage
        exit 0
        ;;
      --domain)
        domain="${2:?Missing value for --domain}"
        shift 2
        ;;
      -*)
        echo "Unknown option: $1" >&2
        usage >&2
        exit 1
        ;;
      *)
        if [[ -z "$src_host" ]]; then
          src_host="$1"
        elif [[ -z "$dst_host" ]]; then
          dst_host="$1"
        elif [[ -z "$src_key_path" ]]; then
          src_key_path="$1"
        elif [[ -z "$dst_key_path" ]]; then
          dst_key_path="$1"
        else
          usage >&2
          exit 1
        fi
        shift
        ;;
    esac
  done

  if [[ -z "$src_host" || -z "$dst_host" || -z "$src_key_path" ]]; then
    usage >&2
    exit 1
  fi
  if [[ -z "$dst_key_path" ]]; then
    dst_key_path="$src_key_path"
  fi

  local src_key_path_array
  local dst_key_path_index
  src_key_path_array="$(path_to_jq_array "$src_key_path")"
  dst_key_path_index="$(path_to_sops_index "$dst_key_path")"

  local repo_root
  repo_root="$(resolve_repo_root)"
  # shellcheck disable=SC1091
  source "${repo_root}/apps/_helpers/host-aliases.sh"
  # shellcheck disable=SC1091
  source "${repo_root}/apps/_helpers/secret-domains.sh"
  domain="$(resolve_secret_domain "$domain")"
  src_host="$(canonical_secret_host "$repo_root" "$domain" "$src_host")"
  dst_host="$(canonical_secret_host "$repo_root" "$domain" "$dst_host")"

  local src_secret
  local dst_secret
  src_secret="$(secret_file_path "$repo_root" "$domain" "$src_host")"
  dst_secret="$(secret_file_path "$repo_root" "$domain" "$dst_host")"

  if [[ ! -f "$src_secret" ]]; then
    echo "Source secret not found: $src_secret"
    exit 1
  fi
  if [[ ! -f "$dst_secret" ]]; then
    echo "Destination secret not found: $dst_secret"
    exit 1
  fi

  local src_plain
  local src_json
  local value_json
  src_plain="$(mktemp)"
  src_json="$(mktemp)"
  value_json="$(mktemp)"
  trap 'rm -f "${src_plain:-}" "${src_json:-}" "${value_json:-}"' EXIT

  sops --decrypt "$src_secret" > "$src_plain"
  yq -o=json '.' "$src_plain" > "$src_json"

  if ! jq -e --argjson path "${src_key_path_array}" 'getpath($path) != null' "$src_json" >/dev/null; then
    echo "Path not found in source secret: $src_key_path"
    exit 1
  fi

  jq -c --argjson path "${src_key_path_array}" 'getpath($path)' "$src_json" > "$value_json"
  sops set --idempotent --value-stdin "$dst_secret" "$dst_key_path_index" < "$value_json"

  if [[ "$src_key_path" == "$dst_key_path" ]]; then
    echo "Copied ${src_key_path} from ${src_host} to ${dst_host}."
  else
    echo "Copied ${src_key_path} from ${src_host} to ${dst_host}:${dst_key_path}."
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
