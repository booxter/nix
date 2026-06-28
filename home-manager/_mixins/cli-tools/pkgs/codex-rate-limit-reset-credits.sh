#!/usr/bin/env bash
set -euo pipefail

AUTH_FILE="${1:-${HOME}/.codex/auth.json}"
ENDPOINT="https://chatgpt.com/backend-api/wham/rate-limit-reset-credits"

if [ ! -f "$AUTH_FILE" ]; then
  echo "Codex auth file not found: ${AUTH_FILE}" >&2
  exit 1
fi

TOKEN="$(jq -r '.tokens.access_token // empty' "$AUTH_FILE")"
if [ -z "$TOKEN" ]; then
  echo "No access token found in ${AUTH_FILE}" >&2
  exit 1
fi

RESPONSE="$(curl -fsS -H "Authorization: Bearer ${TOKEN}" "$ENDPOINT")"

AVAILABLE="$(printf '%s' "$RESPONSE" | jq -r '.available_count // empty')"
if [ -z "$AVAILABLE" ] || [ "$AVAILABLE" = "null" ]; then
  echo "Unexpected response: missing available_count" >&2
  printf '%s\n' "$RESPONSE" >&2
  exit 1
fi

echo "available_count: ${AVAILABLE}"
echo "credits:"
printf '%s\n' "$RESPONSE" | jq -r '.credits[] | "  - expires_at: " + ((.expires_at // "<missing>"))' \
  2>/dev/null || true

