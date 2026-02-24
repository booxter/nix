#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/sops-cat.sh [HOST]
  scripts/sops-cat.sh --help

Decrypt and print secrets/HOST.yaml.
If HOST is omitted, the current short hostname is used.
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
        usage >&2
        exit 1
      fi
      ;;
  esac
done

if [[ -z "$host" ]]; then
  host="$(hostname -s)"
fi

repo_root="$(resolve_repo_root)"
secret="${repo_root}/secrets/${host}.yaml"

if [[ ! -f "$secret" ]]; then
  echo "Secret not found: $secret"
  exit 1
fi

sops --decrypt "$secret"
