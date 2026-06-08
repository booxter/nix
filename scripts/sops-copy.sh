#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/sops-copy.sh SRC_HOST DST_HOST SRC_KEY_PATH [DST_KEY_PATH]
  scripts/sops-copy.sh --help

Copy SRC_KEY_PATH from secrets/SRC_HOST.yaml into secrets/DST_HOST.yaml.
If DST_KEY_PATH is omitted, SRC_KEY_PATH is used in the destination too.
Example:
  scripts/sops-copy.sh mair prx1-lab attic
  scripts/sops-copy.sh prx1-lab prox-gwvm nut/users/upsslave/password nut/monitors/prx1-lab/password
EOF
}

copy_yaml_path() {
  local src_plain="$1"
  local dst_plain="$2"
  local out="$3"
  local src_path_array="$4"
  local dst_path_array="$5"
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
    --argjson srcPath "${src_path_array}" \
    --argjson dstPath "${dst_path_array}" \
    '$dst[0] | setpath($dstPath; ($src[0] | getpath($srcPath)))' > "$merged_json"
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

main() {
  local src_host=""
  local dst_host=""
  local src_key_path=""
  local dst_key_path=""

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
  local dst_key_path_array
  src_key_path_array="$(path_to_jq_array "$src_key_path")"
  dst_key_path_array="$(path_to_jq_array "$dst_key_path")"

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

  if ! yq -o=json '.' "$src_plain" | jq -e --argjson path "${src_key_path_array}" 'getpath($path) != null' >/dev/null; then
    echo "Path not found in source secret: $src_key_path"
    exit 1
  fi

  copy_yaml_path "$src_plain" "$dst_plain" "$merged_plain" "$src_key_path_array" "$dst_key_path_array"

  sops --encrypt --filename-override "$dst_secret" --input-type yaml --output-type yaml "$merged_plain" > "$encrypted"
  mv "$encrypted" "$dst_secret"

  if [[ "$src_key_path" == "$dst_key_path" ]]; then
    echo "Copied ${src_key_path} from ${src_host} to ${dst_host}."
  else
    echo "Copied ${src_key_path} from ${src_host} to ${dst_host}:${dst_key_path}."
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
