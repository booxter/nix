#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/sops-copy.sh SRC_HOST DST_HOST KEY_PATH
  scripts/sops-copy.sh --help

Copy KEY_PATH from secrets/SRC_HOST.yaml into secrets/DST_HOST.yaml.
Example:
  scripts/sops-copy.sh mair prx1-lab attic
EOF
}

copy_top_level_yaml_path() {
  local src_plain="$1"
  local dst_plain="$2"
  local out="$3"
  local src_json
  local dst_json
  local merged_json

  src_json="$(mktemp)"
  dst_json="$(mktemp)"
  merged_json="$(mktemp)"
  yq -o=json '.' "$src_plain" > "$src_json"
  yq -o=json '.' "$dst_plain" > "$dst_json"
  jq -n \
    --slurpfile src "$src_json" \
    --slurpfile dst "$dst_json" \
    --argjson path "${key_path_array}" \
    '$dst[0] | setpath($path; ($src[0] | getpath($path)))' > "$merged_json"
  yq -P '.' "$merged_json" > "$out"
  rm -f "$src_json" "$dst_json" "$merged_json"
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
  local src_host=""
  local dst_host=""
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
        if [[ -z "$src_host" ]]; then
          src_host="$1"
        elif [[ -z "$dst_host" ]]; then
          dst_host="$1"
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

  if [[ -z "$src_host" || -z "$dst_host" || -z "$key_path" ]]; then
    usage >&2
    exit 1
  fi

  local key_path_array
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

  if ! yq -o=json '.' "$src_plain" | jq -e --argjson path "${key_path_array}" 'getpath($path) != null' >/dev/null; then
    echo "Path not found in source secret: $key_path"
    exit 1
  fi

  copy_top_level_yaml_path "$src_plain" "$dst_plain" "$merged_plain"

  sops --encrypt --filename-override "$dst_secret" --input-type yaml --output-type yaml "$merged_plain" > "$encrypted"
  mv "$encrypted" "$dst_secret"

  echo "Copied ${key_path} from ${src_host} to ${dst_host}."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
