#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  apps/sops/sops-ups-sync.sh [--domain DOMAIN] --all
  apps/sops/sops-ups-sync.sh [--domain DOMAIN] SERVER [CLIENT...]
  apps/sops/sops-ups-sync.sh --help

Copy a UPS server's nut/users/upsslave/password secret to each client's
nut/monitors/SERVER/password secret.

With SERVER and no CLIENT arguments, clients are calculated from inventory.
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

CLIENTS_BY_SERVER_JSON=""

load_clients_by_server() {
  if [[ -n "$CLIENTS_BY_SERVER_JSON" ]]; then
    printf '%s\n' "$CLIENTS_BY_SERVER_JSON"
    return
  fi

  if [[ -n "${UPS_CLIENTS_BY_SERVER_FILE:-}" ]]; then
    CLIENTS_BY_SERVER_JSON="$(cat "$UPS_CLIENTS_BY_SERVER_FILE")"
    printf '%s\n' "$CLIENTS_BY_SERVER_JSON"
    return
  fi

  local repo_root="$1"
  CLIENTS_BY_SERVER_JSON="$(
    SOPS_UPS_SYNC_REPO_ROOT="$repo_root" nix eval --impure --json --expr '
      let
        repo = builtins.getEnv "SOPS_UPS_SYNC_REPO_ROOT";
        flake = builtins.getFlake ("git+file://" + repo);
      in
        import (repo + "/lib/ups-clients.nix") { lib = flake.inputs.nixpkgs.lib; }
    '
  )"
  printf '%s\n' "$CLIENTS_BY_SERVER_JSON"
}

default_clients_for_server() {
  local repo_root="$1"
  local server="$2"
  local clients_json
  clients_json="$(load_clients_by_server "$repo_root")"
  jq -r --arg server "$server" '.[$server] // [] | .[]' <<< "$clients_json"
}

all_servers() {
  local repo_root="$1"
  local clients_json
  clients_json="$(load_clients_by_server "$repo_root")"
  jq -r 'keys[]' <<< "$clients_json"
}

sync_server() {
  local repo_root="$1"
  local domain="$2"
  local server="$3"
  shift 3
  local clients=("$@")

  if [[ "${#clients[@]}" -eq 0 ]]; then
    mapfile -t clients < <(default_clients_for_server "$repo_root" "$server")
  fi
  if [[ "${#clients[@]}" -eq 0 ]]; then
    echo "No UPS clients to sync for ${server}."
    return
  fi

  local client
  for client in "${clients[@]}"; do
    "${BASH}" "${repo_root}/apps/sops/sops-copy.sh" \
      --domain "$domain" \
      "$server" \
      "$client" \
      "nut/users/upsslave/password" \
      "nut/monitors/${server}/password"
    echo "Synced ${server} UPS password to ${client}."
  done
}

main() {
  local repo_root
  repo_root="$(resolve_repo_root)"

  local domain=""
  if [[ "${1:-}" == "--domain" ]]; then
    domain="${2:?Missing value for --domain}"
    shift 2
  fi

  # shellcheck disable=SC1091
  source "${repo_root}/apps/_helpers/secret-domains.sh"
  domain="$(resolve_secret_domain "$domain")"

  if [[ "$#" -eq 0 ]]; then
    usage >&2
    exit 1
  fi

  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    --all)
      shift
      if [[ "$#" -ne 0 ]]; then
        usage >&2
        exit 1
      fi
      local servers
      mapfile -t servers < <(all_servers "$repo_root")
      if [[ "${#servers[@]}" -eq 0 ]]; then
        echo "No UPS clients found in inventory."
        exit 1
      fi
      local server
      for server in "${servers[@]}"; do
        sync_server "$repo_root" "$domain" "$server"
      done
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      local server="$1"
      shift
      sync_server "$repo_root" "$domain" "$server" "$@"
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
