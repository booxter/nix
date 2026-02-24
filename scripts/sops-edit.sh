#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/sops-edit.sh [HOST]
  scripts/sops-edit.sh --help

If HOST is omitted, the current short hostname is used.
If a template exists for HOST, merge it into the secret first.
Then open the secret for editing with sops.
EOF
}

host=""

resolve_repo_root() {
  if git -C "$PWD" rev-parse --show-toplevel >/dev/null 2>&1; then
    git -C "$PWD" rev-parse --show-toplevel
    return
  fi
  local script_dir
  script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
  cd -- "${script_dir}/.." && pwd
}

repo_root="$(resolve_repo_root)"
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
        usage >&2
        exit 1
      fi
      ;;
  esac
done

if [[ -z "$host" ]]; then
  host="$(hostname -s)"
fi

default_template="${repo_root}/secrets/_template.yaml"
secret="${repo_root}/secrets/${host}.yaml"

if [[ ! -f "$secret" ]]; then
  echo "Secret not found: $secret"
  exit 1
fi

if [[ -f "$default_template" ]]; then
  "${repo_root}/scripts/sops-update.sh" "$host"
fi

sops "$secret"
