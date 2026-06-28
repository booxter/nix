#!/usr/bin/env bash
set -euo pipefail

AUTH_FILE="${HOME}/.codex/auth.json"
FORMAT="text"
ENDPOINT="https://chatgpt.com/backend-api/wham/usage"

usage() {
  cat <<'USAGE'
Usage: codex-usage-status [--json] [--text] [--auth-file PATH]

Print Codex rate-limit state from the local Codex OAuth session.
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
if [ -z "$TOKEN" ]; then
  echo "No access token found in ${AUTH_FILE}" >&2
  exit 1
fi

RESPONSE="$(curl -fsS -H "Authorization: Bearer ${TOKEN}" "$ENDPOINT")"

if [ "$FORMAT" = "json" ]; then
  printf '%s\n' "$RESPONSE" | jq -c '
    def window($source):
      if $source == null then
        null
      else
        {
          used_percent: ($source.used_percent // null),
          remaining_percent: (
            if ($source.used_percent | type) == "number" then
              (100 - $source.used_percent) | floor
            else
              null
            end
          ),
          limit_window_seconds: ($source.limit_window_seconds // null),
          reset_after_seconds: ($source.reset_after_seconds // null),
          reset_at: ($source.reset_at // null)
        }
      end;

    {
      allowed: .rate_limit.allowed,
      limit_reached: .rate_limit.limit_reached,
      limit_reached_type: (.rate_limit_reached_type // null),
      windows: {
        five_hour: window(.rate_limit.primary_window),
        weekly: window(.rate_limit.secondary_window)
      },
      rate_limit_reset_credits: {
        available_count: (.rate_limit_reset_credits.available_count // 0)
      }
    }
  '
else
  printf '%s\n' "$RESPONSE" | jq -r '
    def fmt_window($label; $source):
      if $source == null then
        "\($label): unavailable"
      else
        "\($label): \(if ($source.used_percent | type) == "number" then (100 - $source.used_percent) | floor else "?" end)% remaining, reset_after_seconds=\($source.reset_after_seconds // "?"), reset_at=\($source.reset_at // "?")"
      end;

    "allowed: \(if .rate_limit.allowed == null then "?" else .rate_limit.allowed end)",
    "limit_reached: \(if .rate_limit.limit_reached == null then "?" else .rate_limit.limit_reached end)",
    fmt_window("5h"; .rate_limit.primary_window),
    fmt_window("1w"; .rate_limit.secondary_window),
    "rate_limit_reset_credits: \(.rate_limit_reset_credits.available_count // 0)"
  '
fi
