#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/sops-edit.sh --host HOST

If a template exists for HOST, merge it into the secret first.
Then open the secret for editing with sops.
EOF
}

host=""
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/.." && pwd)"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)
      host="$2"
      shift 2
      ;;
    *)
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$host" ]]; then
  usage
  exit 1
fi

template="${repo_root}/secrets/_templates/${host}.yaml"
secret="${repo_root}/secrets/${host}.yaml"

if [[ ! -f "$secret" ]]; then
  echo "Secret not found: $secret"
  exit 1
fi

if [[ -f "$template" ]]; then
  "${repo_root}/scripts/sops-merge-template.sh" --host "$host"
fi

sops "$secret"
