#!/usr/bin/env bats

setup() {
  tmpdir="$(mktemp -d)"
  mkdir -p "$tmpdir/bin"
  plugin="$PWD/home-manager/_mixins/sketchybar/sketchybar/plugins/github-status.sh"
  bash_path="$(command -v bash)"

  printf '#!%s\n' "$bash_path" >"$tmpdir/bin/curl"
  cat >>"$tmpdir/bin/curl" <<'EOF'
printf '%s\n' "$*" >"$GITHUB_STATUS_TEST_CURL_ARGS"
if [[ -n "${GITHUB_STATUS_TEST_CURL_FAILURE:-}" ]]; then
  exit 22
fi
cat "$GITHUB_STATUS_TEST_RESPONSE"
EOF

  printf '#!%s\n' "$bash_path" >"$tmpdir/bin/sketchybar"
  cat >>"$tmpdir/bin/sketchybar" <<'EOF'
printf '%s\n' "$*"
EOF
  chmod +x "$tmpdir/bin/curl" "$tmpdir/bin/sketchybar"

  export NAME=github-status
  export GITHUB_STATUS_URL=https://github-status.test/api/v2/summary.json
  export GITHUB_STATUS_TEST_CURL_ARGS="$tmpdir/curl-args"
  export CURL="$tmpdir/bin/curl"
}

teardown() {
  rm -rf "$tmpdir"
}

write_response() {
  printf '%s\n' "$1" >"$tmpdir/summary.json"
  export GITHUB_STATUS_TEST_RESPONSE="$tmpdir/summary.json"
}

@test "hides the item when GitHub is fully operational" {
  write_response '{"status":{"indicator":"none"},"components":[{"status":"operational"}],"incidents":[]}'

  run env PATH="$tmpdir/bin:$PATH" bash "$plugin"

  [ "$status" -eq 0 ]
  [[ "$output" == *"drawing=off"* ]]
  run grep -F -- "--max-time 10 $GITHUB_STATUS_URL" "$GITHUB_STATUS_TEST_CURL_ARGS"
  [ "$status" -eq 0 ]
}

@test "shows a red GitHub icon for a degraded aggregate status" {
  write_response '{"status":{"indicator":"minor"},"components":[{"status":"operational"}],"incidents":[]}'

  run env PATH="$tmpdir/bin:$PATH" bash "$plugin"

  [ "$status" -eq 0 ]
  [[ "$output" == *"drawing=on"* ]]
  [[ "$output" == *"icon="* ]]
  [[ "$output" == *"icon.color=0xfff7768e"* ]]
  [[ "$output" == *"label.drawing=off"* ]]
}

@test "shows the item for a degraded component" {
  write_response '{"status":{"indicator":"none"},"components":[{"status":"degraded_performance"}],"incidents":[]}'

  run env PATH="$tmpdir/bin:$PATH" bash "$plugin"

  [ "$status" -eq 0 ]
  [[ "$output" == *"drawing=on"* ]]
}

@test "shows the item for an unresolved incident" {
  write_response '{"status":{"indicator":"none"},"components":[{"status":"operational"}],"incidents":[{"status":"investigating"}]}'

  run env PATH="$tmpdir/bin:$PATH" bash "$plugin"

  [ "$status" -eq 0 ]
  [[ "$output" == *"drawing=on"* ]]
}

@test "preserves the last state when GitHub Status is unavailable" {
  export GITHUB_STATUS_TEST_CURL_FAILURE=1

  run env PATH="$tmpdir/bin:$PATH" bash "$plugin"

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "preserves the last state for an invalid API response" {
  write_response '{"status":"ok"}'

  run env PATH="$tmpdir/bin:$PATH" bash "$plugin"

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
