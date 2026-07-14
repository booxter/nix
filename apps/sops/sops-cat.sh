#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  apps/sops/sops-cat.sh [--domain DOMAIN] [HOST]
  apps/sops/sops-cat.sh --help

Decrypt and print secrets/DOMAIN/HOST.yaml.
If HOST is omitted, the current short hostname is used.
If DOMAIN is omitted, the current machine's inventory domain is used.
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

host=""
domain=""
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
# shellcheck disable=SC1091
source "${repo_root}/apps/_helpers/host-aliases.sh"
# shellcheck disable=SC1091
source "${repo_root}/apps/_helpers/secret-domains.sh"
domain="$(resolve_secret_domain "$domain")"
host="$(canonical_secret_host "$repo_root" "$domain" "$host")"
secret="$(secret_file_path "$repo_root" "$domain" "$host")"

if [[ ! -f "$secret" ]]; then
  echo "Secret not found: $secret"
  exit 1
fi

sops --decrypt "$secret"
