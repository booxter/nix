#!/usr/bin/env bats

setup() {
  tmpdir="$(mktemp -d)"
  mkdir -p "$tmpdir/bin" "$tmpdir/home/.codex"
  usage_status="$PWD/home-manager/_mixins/agents/pkgs/codex-usage-status.sh"
  bash_path="$(command -v bash)"

  jq -n '{ tokens: { access_token: "test-token" } }' >"$tmpdir/auth.json"
  cp "$tmpdir/auth.json" "$tmpdir/home/.codex/auth.json"

  printf '#!%s\n' "$bash_path" >"$tmpdir/bin/curl"
  cat >>"$tmpdir/bin/curl" <<'EOF'
case "${!#}" in
  */rate-limit-reset-credits)
    printf '%s\n' '{"available_count":0,"credits":[]}'
    ;;
  *)
    cat "$CODEX_USAGE_TEST_RESPONSE"
    ;;
esac
EOF
  chmod +x "$tmpdir/bin/curl"
}

teardown() {
  rm -rf "$tmpdir"
}

@test "normalizes the original five-hour and weekly windows by duration" {
  jq -n '{
    rate_limit: {
      allowed: true,
      limit_reached: false,
      primary_window: {
        used_percent: 4,
        limit_window_seconds: 18000,
        reset_after_seconds: 17000
      },
      secondary_window: {
        used_percent: 27,
        limit_window_seconds: 604800,
        reset_after_seconds: 590000
      }
    }
  }' >"$tmpdir/usage.json"
  export CODEX_USAGE_TEST_RESPONSE="$tmpdir/usage.json"

  run env PATH="$tmpdir/bin:$PATH" bash "$usage_status" --json --auth-file "$tmpdir/auth.json"

  [ "$status" -eq 0 ]
  jq -e '
    .windows.five_hour.remaining_percent == 96
      and .windows.weekly.remaining_percent == 73
  ' <<<"$output"
}

@test "recognizes a weekly window moved into the primary slot" {
  jq -n '{
    rate_limit: {
      allowed: true,
      limit_reached: true,
      primary_window: {
        used_percent: 4,
        limit_window_seconds: 604800,
        reset_after_seconds: 590000
      },
      secondary_window: null
    },
    rate_limit_reached_type: "primary"
  }' >"$tmpdir/usage.json"
  export CODEX_USAGE_TEST_RESPONSE="$tmpdir/usage.json"

  run env PATH="$tmpdir/bin:$PATH" bash "$usage_status" --json --auth-file "$tmpdir/auth.json"

  [ "$status" -eq 0 ]
  jq -e '
    .windows.five_hour == null
      and .windows.weekly.remaining_percent == 96
      and .limit_reached_type == "weekly"
  ' <<<"$output"
}
