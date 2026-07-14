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

registered_secret_domain() {
  local machine="$1"
  local domains_file="${SOPS_SECRET_DOMAINS_FILE:-}"

  if [[ -z "$domains_file" || ! -f "$domains_file" ]]; then
    echo "SOPS_SECRET_DOMAINS_FILE is not set to a readable inventory map." >&2
    return 1
  fi
  jq -er --arg machine "$machine" '.[$machine]' "$domains_file"
}

assert_secret_domain_host() {
  local domain="$1"
  local machine="$2"
  local registered

  if ! registered="$(registered_secret_domain "$machine")"; then
    echo "No secret domain is registered for host: $machine" >&2
    return 1
  fi
  if [[ "$registered" != "$domain" ]]; then
    echo "Host $machine belongs to secret domain '$registered', not '$domain'." >&2
    return 1
  fi
}

domain_age_identity_file() {
  local domain="$1"

  if [[ "$domain" == "main" ]]; then
    return 1
  fi
  if [[ "$(uname -s)" == "Darwin" ]]; then
    printf '%s/Library/Application Support/sops/age/%s.txt\n' "$HOME" "$domain"
  else
    printf '%s/sops/age/%s.txt\n' "${XDG_CONFIG_HOME:-${HOME}/.config}" "$domain"
  fi
}

configure_domain_age_identity() {
  local domain="$1"
  local identity_file

  if [[ "$domain" == "main" || -n "${SOPS_AGE_KEY_FILE:-}" ]]; then
    return
  fi
  identity_file="$(domain_age_identity_file "$domain")"
  if [[ ! -f "$identity_file" ]]; then
    echo "Age identity for secret domain '$domain' not found: $identity_file" >&2
    return 1
  fi
  export SOPS_AGE_KEY_FILE="$identity_file"
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
