#!/usr/bin/env bash
set -euo pipefail

AUTH_FILE="${HOME}/.codex/auth.json"
FORMAT="text"
USAGE_ENDPOINT="https://chatgpt.com/backend-api/wham/usage"

usage() {
  cat <<'USAGE'
Usage: codex-work-usage-status [--json] [--text] [--auth-file PATH]

Print Codex work-account credit usage from the local Codex OAuth session.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --json)
      FORMAT="json"
      shift
      ;;
    --text)
      FORMAT="text"
      shift
      ;;
    --auth-file)
      if [ "$#" -lt 2 ]; then
        echo "--auth-file requires a path" >&2
        exit 2
      fi
      AUTH_FILE="$2"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ ! -f "$AUTH_FILE" ]; then
  echo "Codex auth file not found: ${AUTH_FILE}" >&2
  exit 1
fi

TOKEN="$(jq -r '.tokens.access_token // empty' "$AUTH_FILE")"
ACCOUNT_ID="$(jq -r '.tokens.account_id // empty' "$AUTH_FILE")"
if [ -z "$TOKEN" ]; then
  echo "No access token found in ${AUTH_FILE}" >&2
  exit 1
fi
if [ -z "$ACCOUNT_ID" ]; then
  echo "No account id found in ${AUTH_FILE}" >&2
  exit 1
fi

USAGE_RESPONSE="$(
  curl -fsS \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "ChatGPT-Account-Id: ${ACCOUNT_ID}" \
    -H "OAI-Language: en-US" \
    -H "originator: codex_desktop" \
    "$USAGE_ENDPOINT"
)"

NORMALIZED_RESPONSE="$(
  printf '%s\n' "$USAGE_RESPONSE" | jq -c '
    def number_or_null:
      if type == "number" then
        .
      elif type == "string" then
        try tonumber catch null
      else
        null
      end;

    def month_start_epoch($ts):
      ($ts | gmtime) as $date
      | [$date[0], $date[1], 1, 0, 0, 0, 0, 0]
      | mktime;

    now as $now
    | .spend_control.individual_limit as $limit
    | if $limit == null then
        error("missing spend_control.individual_limit")
      else
        ($limit.limit | number_or_null) as $limit_total
        | ($limit.used | number_or_null) as $used
        | ($limit.remaining | number_or_null) as $remaining
        | ($limit.used_percent | number_or_null) as $used_percent
        | ($limit.remaining_percent | number_or_null) as $remaining_percent
        | ($limit.reset_after_seconds | number_or_null) as $reset_after_seconds
        | ($limit.reset_at | number_or_null) as $reset_at
        | (month_start_epoch($now)) as $window_start_at
        | {
            account_id: (.account_id // null),
            email: (.email // null),
            plan_type: (.plan_type // null),
            reached: (.spend_control.reached // false),
            source: ($limit.source // null),
            limit: $limit_total,
            used: $used,
            remaining: $remaining,
            used_percent: $used_percent,
            remaining_percent: $remaining_percent,
            reset_after_seconds: $reset_after_seconds,
            reset_at: $reset_at,
            window_start_at: $window_start_at,
            window_seconds: (
              if $reset_at == null then
                null
              else
                (($reset_at - $window_start_at) | floor)
              end
            ),
            elapsed_seconds: (($now - $window_start_at) | floor),
            credits: {
              has_credits: (.credits.has_credits // false),
              unlimited: (.credits.unlimited // false),
              overage_limit_reached: (.credits.overage_limit_reached // false),
              balance: (.credits.balance // null)
            }
          }
      end
  '
)"

if [ "$FORMAT" = "json" ]; then
  printf '%s\n' "$NORMALIZED_RESPONSE"
else
  printf '%s\n' "$NORMALIZED_RESPONSE" | jq -r '
    "remaining: \(.remaining_percent // "?")%",
    "used: \(.used_percent // "?")%",
    "credits: \(.remaining // "?") / \(.limit // "?")",
    "reset_after_seconds: \(.reset_after_seconds // "?")",
    "reset_at: \(.reset_at // "?")"
  '
fi
