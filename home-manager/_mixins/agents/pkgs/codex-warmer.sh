#!/usr/bin/env bash
set -euo pipefail

AUTH_FILE="${HOME}/.codex/auth.json"
RESPONSES_ENDPOINT="${CODEX_WARMER_RESPONSES_ENDPOINT:-https://chatgpt.com/backend-api/codex/responses}"

usage() {
  cat <<'USAGE'
Usage: codex-warmer [--auth-file PATH]

Start the Codex five-hour usage window with a minimal request when it is not
already counting down.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
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

status="$(codex-usage-status --json --auth-file "$AUTH_FILE")"
if jq -e '
  .windows.five_hour as $window
  | $window != null
    and ($window.limit_window_seconds | type) == "number"
    and ($window.reset_after_seconds | type) == "number"
    and $window.reset_after_seconds > 0
    and $window.reset_after_seconds < $window.limit_window_seconds
' >/dev/null <<<"$status"; then
  exit 0
fi

token="$(jq -r '.tokens.access_token // empty' "$AUTH_FILE")"
account_id="$(jq -r '.tokens.account_id // empty' "$AUTH_FILE")"
if [ -z "$token" ]; then
  echo "No access token found in ${AUTH_FILE}" >&2
  exit 1
fi
if [ -z "$account_id" ]; then
  echo "No account ID found in ${AUTH_FILE}" >&2
  exit 1
fi

request="$({
  jq -cn '{
    model: "gpt-5.4-mini",
    instructions: "Reply with exactly OK.",
    input: [{
      type: "message",
      role: "user",
      content: [{ type: "input_text", text: "OK" }]
    }],
    tools: [],
    tool_choice: "auto",
    parallel_tool_calls: false,
    reasoning: { effort: "low" },
    store: false,
    stream: true,
    include: [],
    text: { verbosity: "low" }
  }'
})"

response="$(
  curl -fsS \
    -H "Authorization: Bearer ${token}" \
    -H "ChatGPT-Account-ID: ${account_id}" \
    -H "Content-Type: application/json" \
    -H "Accept: text/event-stream" \
    --data-binary "$request" \
    "$RESPONSES_ENDPOINT"
)"

if ! sed -n 's/^data: //p' <<<"$response" \
  | jq -e -s 'any(.[]; .type == "response.completed")' >/dev/null; then
  echo "Codex warm-up request did not complete" >&2
  exit 1
fi

echo "Started the Codex five-hour usage window."
