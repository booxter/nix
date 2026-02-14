#!/usr/bin/env bash
set -euo pipefail

mode="all"
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  cat <<'EOF'
Usage: get-local-builders.sh [--local]

Outputs builders from /etc/nix/nix.conf or /etc/nix/machines.

  --local       Only localhost + linux-builder entries.
EOF
  exit 0
elif [[ "${1:-}" == "--local" ]]; then
  mode="local-only"
fi

builders=""

if [[ -r /etc/nix/nix.conf ]]; then
  builders="$(awk -F= '/^builders[[:space:]]*=/ {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2}' /etc/nix/nix.conf | tail -n 1)"
fi

if [[ -z "$builders" && -r /etc/nix/machines ]]; then
  builders="$(awk 'NF && $1 !~ /^#/' /etc/nix/machines | paste -sd ';' -)"
fi

if [[ -z "$builders" ]]; then
  exit 0
fi

if [[ "$mode" == "local-only" ]]; then
  echo "$builders" | tr ';' '\n' | awk '/localhost|linux-builder/ {print}' | paste -sd ';' -
else
  echo "$builders"
fi
