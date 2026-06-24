#!/usr/bin/env bash
# shellcheck shell=bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  reset-oidc <user-id> [email]

Examples:
  reset-oidc ihar
  reset-oidc kasia kasia.bondarava@gmail.com
EOF
}

if [ "$#" -eq 1 ] && { [ "$1" = "-h" ] || [ "$1" = "--help" ]; }; then
  usage
  exit 0
fi

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  usage >&2
  exit 1
fi

user_id="$1"
email="${2:-}"
ttl_seconds=86400
ssh_target="${RESET_OIDC_SSH_TARGET:-pki}"

if [ -z "$user_id" ]; then
  echo "user-id must be non-empty" >&2
  exit 1
fi

remote_args=("$user_id" "$ttl_seconds")
if [ -n "$email" ]; then
  remote_args+=("$email")
fi

ssh "$ssh_target" sudo -n /run/current-system/sw/bin/bash -s -- \
  "${remote_args[@]}" <<'REMOTE'
set -euo pipefail

export PATH=/run/current-system/sw/bin:/run/wrappers/bin

user_id="$1"
ttl_seconds="$2"
email="${3:-}"

token_dir="$(mktemp -d -t kanidm-reset-oidc.XXXXXX)"
cleanup() {
  rm -rf "$token_dir"
}
trap cleanup EXIT

export KANIDM_TOKEN_CACHE_PATH="$token_dir/tokens.json"
password="$(tr -d '\n' < /run/secrets/kanidmIdmAdminPassword)"
export KANIDM_PASSWORD="$password"
kanidm login -D idm_admin >/dev/null
unset KANIDM_PASSWORD password

cmd=(kanidm person credential send-reset-token "$user_id")
if [ -n "$email" ]; then
  cmd+=("$email")
fi
cmd+=(--ttl "$ttl_seconds")

"${cmd[@]}"
REMOTE

if [ -n "$email" ]; then
  echo "Requested OIDC credential reset email for $user_id at $email."
else
  echo "Requested OIDC credential reset email for $user_id."
fi
