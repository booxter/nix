#!/usr/bin/env bats

setup() {
  tmpdir="$(mktemp -d)"
  mkdir -p "$tmpdir/bin"
  plugin="$PWD/home-manager/_mixins/sketchybar/sketchybar/plugins/alertmanager.sh"
  bash_path="$(command -v bash)"

  printf '#!%s\n' "$bash_path" >"$tmpdir/bin/curl"
  cat >>"$tmpdir/bin/curl" <<'EOF'
printf '%s\n' "$*" >"$ALERTMANAGER_TEST_CURL_ARGS"
if [[ -n "${ALERTMANAGER_TEST_CURL_FAILURE:-}" ]]; then
  exit 22
fi
cat "$ALERTMANAGER_TEST_RESPONSE"
EOF

  printf '#!%s\n' "$bash_path" >"$tmpdir/bin/sketchybar"
  cat >>"$tmpdir/bin/sketchybar" <<'EOF'
printf '%s\n' "$*"
EOF
  chmod +x "$tmpdir/bin/curl" "$tmpdir/bin/sketchybar"

  export NAME=alertmanager
  export ALERTMANAGER_URL=https://alertmanager.test/api/v2/alerts
  export ALERTMANAGER_CA_CERTIFICATE="$tmpdir/root-ca.crt"
  export ALERTMANAGER_CLIENT_CERTIFICATE="$tmpdir/client.crt"
  export ALERTMANAGER_CLIENT_KEY="$tmpdir/client.key"
  export ALERTMANAGER_TEST_CURL_ARGS="$tmpdir/curl-args"
  export CURL="$tmpdir/bin/curl"
}

teardown() {
  rm -rf "$tmpdir"
}

@test "hides the item when there are no firing alerts" {
  printf '%s\n' '[]' >"$tmpdir/alerts.json"
  export ALERTMANAGER_TEST_RESPONSE="$tmpdir/alerts.json"

  run env PATH="$tmpdir/bin:$PATH" bash "$plugin"

  [ "$status" -eq 0 ]
  [[ "$output" == *"drawing=off"* ]]
  run grep -F -- "--cacert $ALERTMANAGER_CA_CERTIFICATE" "$ALERTMANAGER_TEST_CURL_ARGS"
  [ "$status" -eq 0 ]
  run grep -F -- "--cert $ALERTMANAGER_CLIENT_CERTIFICATE" "$ALERTMANAGER_TEST_CURL_ARGS"
  [ "$status" -eq 0 ]
  run grep -F -- "--key $ALERTMANAGER_CLIENT_KEY" "$ALERTMANAGER_TEST_CURL_ARGS"
  [ "$status" -eq 0 ]
}

@test "shows the number of firing alerts" {
  printf '%s\n' '[{"labels":{"alertname":"one"}},{"labels":{"alertname":"two"}}]' >"$tmpdir/alerts.json"
  export ALERTMANAGER_TEST_RESPONSE="$tmpdir/alerts.json"

  run env PATH="$tmpdir/bin:$PATH" bash "$plugin"

  [ "$status" -eq 0 ]
  [[ "$output" == *"drawing=on"* ]]
  [[ "$output" == *"label=2"* ]]
  [[ "$output" == *"label.color=0xfff7768e"* ]]
}

@test "shows an error state when Alertmanager is unavailable" {
  export ALERTMANAGER_TEST_CURL_FAILURE=1

  run env PATH="$tmpdir/bin:$PATH" bash "$plugin"

  [ "$status" -eq 0 ]
  [[ "$output" == *"drawing=on"* ]]
  [[ "$output" == *"label=?"* ]]
  [[ "$output" == *"label.color=0xffe0af68"* ]]
}

@test "shows an error state for an invalid API response" {
  printf '%s\n' '{"status":"ok"}' >"$tmpdir/alerts.json"
  export ALERTMANAGER_TEST_RESPONSE="$tmpdir/alerts.json"

  run env PATH="$tmpdir/bin:$PATH" bash "$plugin"

  [ "$status" -eq 0 ]
  [[ "$output" == *"drawing=on"* ]]
  [[ "$output" == *"label=?"* ]]
}
