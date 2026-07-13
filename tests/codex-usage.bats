#!/usr/bin/env bats

setup() {
  tmpdir="$(mktemp -d)"
  mkdir -p "$tmpdir/bin" "$tmpdir/home/.codex"
  usage_status="$PWD/home-manager/_mixins/agents/pkgs/codex-usage-status.sh"
  sketchybar_plugin="$PWD/home-manager/_mixins/sketchybar/sketchybar/plugins/codex.sh"
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

@test "renders an unavailable window with a compact placeholder" {
  printf '#!%s\n' "$bash_path" >"$tmpdir/bin/codex-usage-status"
  cat >>"$tmpdir/bin/codex-usage-status" <<'EOF'
printf '%s\n' '{
  "limit_reached": false,
  "windows": {
    "five_hour": null,
    "weekly": {
      "used_percent": 4,
      "remaining_percent": 96,
      "limit_window_seconds": 604800,
      "reset_after_seconds": 590000
    }
  },
  "rate_limit_reset_credits": { "available_count": 0 }
}'
EOF
  chmod +x "$tmpdir/bin/codex-usage-status"

  printf '#!%s\n' "$bash_path" >"$tmpdir/bin/sketchybar"
  cat >>"$tmpdir/bin/sketchybar" <<'EOF'
printf '%s\n' "$@"
EOF
  chmod +x "$tmpdir/bin/sketchybar"

  run env HOME="$tmpdir/home" PATH="$tmpdir/bin:$PATH" NAME=codex.5h bash "$sketchybar_plugin"

  [ "$status" -eq 0 ]
  [[ "$output" == *"label=5h ???"* ]]
  [[ "$output" == *"label=1w 96%/6d19h"* ]]
  [[ "$output" != *"?%/?"* ]]
}
