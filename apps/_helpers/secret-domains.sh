#!/usr/bin/env bash
# shellcheck shell=bash

resolve_secret_domain() {
  local explicit_domain="${1:-}"
  local machine
  local domains_file="${SOPS_SECRET_DOMAINS_FILE:-}"

  if [[ -n "$explicit_domain" ]]; then
    if [[ ! "$explicit_domain" =~ ^[a-z][a-z0-9-]*$ ]]; then
      echo "Invalid secret domain: $explicit_domain" >&2
      return 1
    fi
    printf '%s\n' "$explicit_domain"
    return
  fi

  if [[ -z "$domains_file" || ! -f "$domains_file" ]]; then
    echo "SOPS_SECRET_DOMAINS_FILE is not set to a readable inventory map." >&2
    echo "Run this helper through 'nix run .#sops-…' or pass --domain explicitly." >&2
    return 1
  fi

  machine="${SOPS_MACHINE_HOSTNAME:-$(hostname -s)}"
  if ! jq -er --arg machine "$machine" '.[$machine]' "$domains_file"; then
    echo "No secret domain is registered for machine: $machine" >&2
    echo "Pass --domain explicitly or add the machine to fleet inventory." >&2
    return 1
  fi
}

secret_domain_dir() {
  local repo_root="$1"
  local domain="$2"
  printf '%s/secrets/%s\n' "$repo_root" "$domain"
}

secret_file_path() {
  local repo_root="$1"
  local domain="$2"
  local host="$3"
  printf '%s/secrets/%s/%s.yaml\n' "$repo_root" "$domain" "$host"
}
