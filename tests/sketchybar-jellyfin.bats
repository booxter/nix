#!/usr/bin/env bats

setup() {
  tmpdir="$(mktemp -d)"
  mkdir -p "$tmpdir/bin"
  plugin="$PWD/home-manager/_mixins/sketchybar/sketchybar/plugins/jellyfin.sh"
  bash_path="$(command -v bash)"

  printf '#!%s\n' "$bash_path" >"$tmpdir/bin/curl"
  cat >>"$tmpdir/bin/curl" <<'EOF'
printf '%s\n' "$*" >"$JELLYFIN_TEST_CURL_ARGS"
if [[ -n "${JELLYFIN_TEST_CURL_FAILURE:-}" ]]; then
  exit 22
fi
cat "$JELLYFIN_TEST_RESPONSE"
EOF

  printf '#!%s\n' "$bash_path" >"$tmpdir/bin/sketchybar"
  cat >>"$tmpdir/bin/sketchybar" <<'EOF'
printf '%s\n' "$*"
EOF
  chmod +x "$tmpdir/bin/curl" "$tmpdir/bin/sketchybar"

  export NAME=jellyfin
  export JELLYFIN_METRICS_URL=https://jellyfin.test/metrics
  export JELLYFIN_CA_CERTIFICATE="$tmpdir/root-ca.crt"
  export JELLYFIN_CLIENT_CERTIFICATE="$tmpdir/client.crt"
  export JELLYFIN_CLIENT_KEY="$tmpdir/client.key"
  export JELLYFIN_TEST_CURL_ARGS="$tmpdir/curl-args"
  export CURL="$tmpdir/bin/curl"
}

teardown() {
  rm -rf "$tmpdir"
}

write_response() {
  cat >"$tmpdir/metrics"
  export JELLYFIN_TEST_RESPONSE="$tmpdir/metrics"
}

@test "hides the item when there are no active streams" {
  write_response <<'EOF'
jellyfin_scrape_collector_success{collector="playing"} 1
jellyfin_up 1
EOF

  run env PATH="$tmpdir/bin:$PATH" bash "$plugin"

  [ "$status" -eq 0 ]
  [[ "$output" == *"drawing=off"* ]]
  run grep -F -- "--cacert $JELLYFIN_CA_CERTIFICATE" "$JELLYFIN_TEST_CURL_ARGS"
  [ "$status" -eq 0 ]
  run grep -F -- "--cert $JELLYFIN_CLIENT_CERTIFICATE" "$JELLYFIN_TEST_CURL_ARGS"
  [ "$status" -eq 0 ]
  run grep -F -- "--key $JELLYFIN_CLIENT_KEY" "$JELLYFIN_TEST_CURL_ARGS"
  [ "$status" -eq 0 ]
}

@test "shows the number of active audio and video streams" {
  write_response <<'EOF'
jellyfin_scrape_collector_success{collector="playing"} 1
jellyfin_up 1
jellyfin_now_playing_state{device="Living Room",title="A Film",type="Movie",user_id="one",username="One"} 1
jellyfin_now_playing_state{device="Phone",title="A Song",type="Audio",user_id="two",username="Two"} 1
jellyfin_now_playing_state{device="Tablet",title="Paused",type="Episode",user_id="three",username="Three"} 0
jellyfin_now_playing_state{device="Browser",title="Photo",type="Photo",user_id="four",username="Four"} 1
EOF

  run env PATH="$tmpdir/bin:$PATH" bash "$plugin"

  [ "$status" -eq 0 ]
  [[ "$output" == *"drawing=on"* ]]
  [[ "$output" == *"label=2"* ]]
  [[ "$output" == *"label.color=0xffaa5cc3"* ]]
}

@test "shows an error state when the exporter is unavailable" {
  export JELLYFIN_TEST_CURL_FAILURE=1

  run env PATH="$tmpdir/bin:$PATH" bash "$plugin"

  [ "$status" -eq 0 ]
  [[ "$output" == *"drawing=on"* ]]
  [[ "$output" == *"label=?"* ]]
  [[ "$output" == *"label.color=0xffe0af68"* ]]
}

@test "shows an error state when Jellyfin is down" {
  write_response <<'EOF'
jellyfin_scrape_collector_success{collector="playing"} 1
jellyfin_up 0
EOF

  run env PATH="$tmpdir/bin:$PATH" bash "$plugin"

  [ "$status" -eq 0 ]
  [[ "$output" == *"label=?"* ]]
}

@test "shows an error state when the playing collector fails" {
  write_response <<'EOF'
jellyfin_scrape_collector_success{collector="playing"} 0
jellyfin_up 1
EOF

  run env PATH="$tmpdir/bin:$PATH" bash "$plugin"

  [ "$status" -eq 0 ]
  [[ "$output" == *"label=?"* ]]
}

@test "shows an error state for an invalid playback sample" {
  write_response <<'EOF'
jellyfin_scrape_collector_success{collector="playing"} 1
jellyfin_up 1
jellyfin_now_playing_state{device="TV",title="Broken",type="Movie",user_id="one",username="One"} invalid
EOF

  run env PATH="$tmpdir/bin:$PATH" bash "$plugin"

  [ "$status" -eq 0 ]
  [[ "$output" == *"label=?"* ]]
}
