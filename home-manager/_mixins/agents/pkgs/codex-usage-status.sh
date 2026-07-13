#!/usr/bin/env bash
set -euo pipefail

AUTH_FILE="${HOME}/.codex/auth.json"
FORMAT="text"
USAGE_ENDPOINT="https://chatgpt.com/backend-api/wham/usage"
RESET_CREDITS_ENDPOINT="https://chatgpt.com/backend-api/wham/rate-limit-reset-credits"

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

USAGE_RESPONSE="$(curl -fsS -H "Authorization: Bearer ${TOKEN}" "$USAGE_ENDPOINT")"

RESET_CREDITS_RESPONSE="null"
if response="$(curl -fsS -H "Authorization: Bearer ${TOKEN}" "$RESET_CREDITS_ENDPOINT" 2>/dev/null)" \
  && printf '%s\n' "$response" | jq -e . >/dev/null 2>&1; then
  RESET_CREDITS_RESPONSE="$response"
fi

NORMALIZED_RESPONSE="$(
  printf '%s\n' "$USAGE_RESPONSE" | jq -c --argjson reset_credits "$RESET_CREDITS_RESPONSE" '
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

    def window_kind($source):
      if ($source.limit_window_seconds // null) == 18000 then
        "five_hour"
      elif ($source.limit_window_seconds // null) == 604800 then
        "weekly"
      else
        null
      end;

    def window_by_kind($kind; $primary; $secondary):
      if window_kind($primary) == $kind then
        $primary
      elif window_kind($secondary) == $kind then
        $secondary
      else
        null
      end;

    def limit_reached_kind($kind; $primary; $secondary):
      if $kind == "primary" or $kind == "primary_window" then
        window_kind($primary) // $kind
      elif $kind == "secondary" or $kind == "secondary_window" then
        window_kind($secondary) // $kind
      else
        $kind
      end;

    def expires_at_epoch($expires_at):
      if ($expires_at | type) != "string" then
        null
      else
        $expires_at
        | sub("\\.[0-9]+Z$"; "Z")
        | try fromdateiso8601 catch null
      end;

    def reset_credits($fallback; $details; $now):
      ($details // $fallback // {}) as $source
      | [
          $source.credits[]?
          | (.expires_at // null) as $expires_at
          | (expires_at_epoch($expires_at)) as $expires_at_unix
          | {
              expires_at: $expires_at,
              expires_at_unix: $expires_at_unix,
              expires_after_seconds: (
                if $expires_at_unix == null then
                  null
                else
                  (($expires_at_unix - $now) | floor)
                end
              )
            }
        ] as $credits
      | (
          $credits
          | map(select(.expires_after_seconds != null and .expires_after_seconds >= 0))
          | sort_by(.expires_after_seconds)
          | .[0] // null
        ) as $next
      | {
          available_count: ($source.available_count // $fallback.available_count // 0),
          credits: $credits,
          next_expires_at: ($next.expires_at // null),
          next_expires_at_unix: ($next.expires_at_unix // null),
          next_expires_after_seconds: ($next.expires_after_seconds // null)
        };

    now as $now
    | .rate_limit.primary_window as $primary
    | .rate_limit.secondary_window as $secondary
    | {
        allowed: .rate_limit.allowed,
        limit_reached: .rate_limit.limit_reached,
        limit_reached_type: limit_reached_kind(
          (.rate_limit_reached_type // null);
          $primary;
          $secondary
        ),
        windows: {
          five_hour: window(window_by_kind("five_hour"; $primary; $secondary)),
          weekly: window(window_by_kind("weekly"; $primary; $secondary))
        },
        rate_limit_reset_credits: reset_credits(.rate_limit_reset_credits; $reset_credits; $now)
      }
  '
)"

if [ "$FORMAT" = "json" ]; then
  printf '%s\n' "$NORMALIZED_RESPONSE"
else
  printf '%s\n' "$NORMALIZED_RESPONSE" | jq -r '
    def fmt_window($label; $source):
      if $source == null then
        "\($label): unavailable"
      else
        "\($label): \($source.remaining_percent // "?")% remaining, reset_after_seconds=\($source.reset_after_seconds // "?"), reset_at=\($source.reset_at // "?")"
      end;

    def fmt_reset_credits:
      .rate_limit_reset_credits as $credits
      | if $credits.next_expires_at == null then
          "rate_limit_reset_credits: \($credits.available_count // 0)"
        else
          "rate_limit_reset_credits: \($credits.available_count // 0), next_expires_at=\($credits.next_expires_at), next_expires_after_seconds=\($credits.next_expires_after_seconds // "?")"
        end;

    "allowed: \(if .allowed == null then "?" else .allowed end)",
    "limit_reached: \(if .limit_reached == null then "?" else .limit_reached end)",
    fmt_window("5h"; .windows.five_hour),
    fmt_window("1w"; .windows.weekly),
    fmt_reset_credits
  '
fi
