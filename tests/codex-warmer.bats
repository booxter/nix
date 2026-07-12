#!/usr/bin/env bats

setup() {
  tmpdir="$(mktemp -d)"
  mkdir -p "$tmpdir/bin"
  warmer="$PWD/home-manager/_mixins/agents/pkgs/codex-warmer.sh"
  bash_path="$(command -v bash)"

  jq -n '{
    tokens: {
      access_token: "test-token",
      account_id: "test-account"
    }
  }' >"$tmpdir/auth.json"

  printf '#!%s\n' "$bash_path" >"$tmpdir/bin/codex-usage-status"
  cat >>"$tmpdir/bin/codex-usage-status" <<'EOF'
cat "$CODEX_WARMER_TEST_STATUS"
EOF
  chmod +x "$tmpdir/bin/codex-usage-status"

  printf '#!%s\n' "$bash_path" >"$tmpdir/bin/curl"
  cat >>"$tmpdir/bin/curl" <<'EOF'
printf '%s\n' "$@" >"$CODEX_WARMER_TEST_CURL_ARGS"
while [ "$#" -gt 0 ]; do
  if [ "$1" = "--data-binary" ]; then
    printf '%s\n' "$2" >"$CODEX_WARMER_TEST_REQUEST"
    shift 2
  else
    shift
  fi
done
cat "$CODEX_WARMER_TEST_RESPONSE"
EOF
  chmod +x "$tmpdir/bin/curl"

  export CODEX_WARMER_TEST_STATUS="$tmpdir/status.json"
  export CODEX_WARMER_TEST_REQUEST="$tmpdir/request.json"
  export CODEX_WARMER_TEST_RESPONSE="$tmpdir/response.txt"
  export CODEX_WARMER_TEST_CURL_ARGS="$tmpdir/curl.args"
  export CODEX_WARMER_RESPONSES_ENDPOINT="https://example.invalid/codex/responses"
}

teardown() {
  rm -rf "$tmpdir"
}

@test "does nothing while the five-hour window is ticking" {
  jq -n '{
    windows: {
      five_hour: {
        limit_window_seconds: 18000,
        reset_after_seconds: 17999
      }
    }
  }' >"$CODEX_WARMER_TEST_STATUS"

  run env PATH="$tmpdir/bin:$PATH" bash "$warmer" --auth-file "$tmpdir/auth.json"

  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$CODEX_WARMER_TEST_REQUEST" ]
}

@test "starts an inactive five-hour window with a minimal request" {
  jq -n '{
    windows: {
      five_hour: {
        limit_window_seconds: 18000,
        reset_after_seconds: 0
      }
    }
  }' >"$CODEX_WARMER_TEST_STATUS"
  printf '%s\n' 'data: {"type":"response.completed"}' >"$CODEX_WARMER_TEST_RESPONSE"

  run env PATH="$tmpdir/bin:$PATH" bash "$warmer" --auth-file "$tmpdir/auth.json"

  [ "$status" -eq 0 ]
  [ "$output" = "Started the Codex five-hour usage window." ]
  jq -e '
    .model == "gpt-5.4-mini"
      and .reasoning.effort == "low"
      and .text.verbosity == "low"
      and .tools == []
      and .input[0].content[0].text == "OK"
  ' "$CODEX_WARMER_TEST_REQUEST"
  grep -Fx "Authorization: Bearer test-token" "$CODEX_WARMER_TEST_CURL_ARGS"
  grep -Fx "ChatGPT-Account-ID: test-account" "$CODEX_WARMER_TEST_CURL_ARGS"
}

@test "fails when the warm-up response does not complete" {
  jq -n '{ windows: { five_hour: null } }' >"$CODEX_WARMER_TEST_STATUS"
  printf '%s\n' 'data: {"type":"response.failed"}' >"$CODEX_WARMER_TEST_RESPONSE"

  run env PATH="$tmpdir/bin:$PATH" bash "$warmer" --auth-file "$tmpdir/auth.json"

  [ "$status" -eq 1 ]
  [[ "$output" == *"Codex warm-up request did not complete"* ]]
}
