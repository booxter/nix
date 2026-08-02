#!/usr/bin/env bats

setup() {
  tmpdir="$(mktemp -d)"
  mkdir -p "$tmpdir/bin"
  plugin="${SKETCHYBAR_PLUGIN_DIR:-$BATS_TEST_DIRNAME/../plugins}/jellyfin.sh"
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
  unset SENDER
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
jellyfin_scrape_collector_success{collector="users"} 1
jellyfin_up 1
EOF

  run env PATH="$tmpdir/bin:$PATH" bash "$plugin"

  [ "$status" -eq 0 ]
  [[ "$output" == *"drawing=off"* ]]
  [[ "$output" == *"popup.drawing=off"* ]]
  run grep -F -- "--cacert $JELLYFIN_CA_CERTIFICATE" "$JELLYFIN_TEST_CURL_ARGS"
  [ "$status" -eq 0 ]
  run grep -F -- "--cert $JELLYFIN_CLIENT_CERTIFICATE" "$JELLYFIN_TEST_CURL_ARGS"
  [ "$status" -eq 0 ]
  run grep -F -- "--key $JELLYFIN_CLIENT_KEY" "$JELLYFIN_TEST_CURL_ARGS"
  [ "$status" -eq 0 ]
}

@test "shows session details for active and paused streams" {
  write_response <<'EOF'
jellyfin_scrape_collector_success{collector="playing"} 1
jellyfin_scrape_collector_success{collector="users"} 1
jellyfin_up 1
jellyfin_user_active{client="Jellyfin Web",device="Living Room",ip_address="192.168.1.20",user_id="one",username="One"} 1
jellyfin_user_active{client="Jellyfin Mobile",device="Phone",ip_address="8.8.8.8",user_id="two",username="Two"} 1
jellyfin_now_playing_state{device="Living Room",method="DirectPlay",title="A Film",type="Movie",user_id="one",username="One"} 1
jellyfin_now_playing_bitrate_bits_per_second{device="Living Room",method="DirectPlay",title="A Film",type="Movie",user_id="one",username="One"} 30000000
jellyfin_now_playing_remaining{device="Living Room",method="DirectPlay",title="A Film",type="Movie",user_id="one",username="One"} 2040
jellyfin_now_playing_progress{device="Living Room",method="DirectPlay",title="A Film",type="Movie",user_id="one",username="One"} 42
jellyfin_now_playing_state{device="Phone",method="Transcode",title="A Song",type="Audio",user_id="two",username="Two"} 1
jellyfin_now_playing_bitrate_bits_per_second{device="Phone",method="Transcode",title="A Song",type="Audio",user_id="two",username="Two"} 10000000
jellyfin_now_playing_state{device="Tablet",method="DirectStream",series_episode="5",series_season="2",series_title="A Series",title="The Episode",type="Episode",user_id="three",username="Three"} 0
jellyfin_now_playing_bitrate_bits_per_second{device="Tablet",method="DirectStream",series_episode="5",series_season="2",series_title="A Series",title="The Episode",type="Episode",user_id="three",username="Three"} 5000000
jellyfin_now_playing_progress{device="Tablet",method="DirectStream",series_episode="5",series_season="2",series_title="A Series",title="The Episode",type="Episode",user_id="three",username="Three"} 61
jellyfin_now_playing_state{device="Browser",title="Photo",type="Photo",user_id="four",username="Four"} 1
EOF

  run env PATH="$tmpdir/bin:$PATH" bash "$plugin"

  [ "$status" -eq 0 ]
  [[ "$output" == *"drawing=on"* ]]
  [[ "$output" == *"label=3"* ]]
  [[ "$output" == *"label.color=0xffd3869b"* ]]
  [[ "$output" == *"label=LAN · One · Living Room · A Film — 34m left · direct"* ]]
  [[ "$output" == *"label=WAN · Two · Phone · A Song — playing · transcode"* ]]
  [[ "$output" == *"label=unknown · Three · Tablet · A Series S2E5 — The Episode — paused at 61% · direct stream"* ]]
  [[ "$output" == *"--set jellyfin.bandwidth drawing=on label=WAN 10 Mbit · LAN 30 Mbit"* ]]
  [[ "$output" == *"A Film — 34m left · direct · 30 Mbit"* ]]
  [[ "$output" == *"A Song — playing · transcode · 10 Mbit"* ]]
  [[ "$output" == *"The Episode — paused at 61% · direct stream · 5 Mbit"* ]]
  [[ "$output" != *"Unknown 5 Mbit"* ]]
  [[ "$output" != *"ip_address="* ]]
}

@test "refreshes and toggles the popup when clicked" {
  write_response <<'EOF'
jellyfin_scrape_collector_success{collector="playing"} 1
jellyfin_scrape_collector_success{collector="users"} 1
jellyfin_up 1
jellyfin_user_active{client="Jellyfin Web",device="TV",ip_address="10.0.0.2",user_id="one",username="One"} 1
jellyfin_now_playing_state{device="TV",method="DirectPlay",title="A Film",type="Movie",user_id="one",username="One"} 1
EOF

  run env PATH="$tmpdir/bin:$PATH" SENDER=mouse.clicked bash "$plugin"

  [ "$status" -eq 0 ]
  [[ "$output" == *"popup.drawing=toggle"* ]]
}

@test "marks aggregate traffic as incomplete when bitrate is missing" {
  write_response <<'EOF'
jellyfin_scrape_collector_success{collector="playing"} 1
jellyfin_scrape_collector_success{collector="users"} 1
jellyfin_up 1
jellyfin_user_active{client="Jellyfin Web",device="TV",ip_address="8.8.8.8",user_id="one",username="One"} 1
jellyfin_user_active{client="Jellyfin Mobile",device="Phone",ip_address="1.1.1.1",user_id="two",username="Two"} 1
jellyfin_now_playing_state{device="TV",method="DirectPlay",title="A Film",type="Movie",user_id="one",username="One"} 1
jellyfin_now_playing_bitrate_bits_per_second{device="TV",method="DirectPlay",title="A Film",type="Movie",user_id="one",username="One"} 10500000
jellyfin_now_playing_state{device="Phone",method="Transcode",title="A Song",type="Audio",user_id="two",username="Two"} 1
EOF

  run env PATH="$tmpdir/bin:$PATH" bash "$plugin"

  [ "$status" -eq 0 ]
  [[ "$output" == *"--set jellyfin.bandwidth drawing=on label=WAN ≥10.5 Mbit · LAN 0 Mbit"* ]]
}

@test "shows an error state when the exporter is unavailable" {
  export JELLYFIN_TEST_CURL_FAILURE=1

  run env PATH="$tmpdir/bin:$PATH" bash "$plugin"

  [ "$status" -eq 0 ]
  [[ "$output" == *"drawing=on"* ]]
  [[ "$output" == *"label=?"* ]]
  [[ "$output" == *"label.color=0xfffabd2f"* ]]
}

@test "shows an error state when Jellyfin is down" {
  write_response <<'EOF'
jellyfin_scrape_collector_success{collector="playing"} 1
jellyfin_scrape_collector_success{collector="users"} 1
jellyfin_up 0
EOF

  run env PATH="$tmpdir/bin:$PATH" bash "$plugin"

  [ "$status" -eq 0 ]
  [[ "$output" == *"label=?"* ]]
}

@test "shows an error state when the playing collector fails" {
  write_response <<'EOF'
jellyfin_scrape_collector_success{collector="playing"} 0
jellyfin_scrape_collector_success{collector="users"} 1
jellyfin_up 1
EOF

  run env PATH="$tmpdir/bin:$PATH" bash "$plugin"

  [ "$status" -eq 0 ]
  [[ "$output" == *"label=?"* ]]
}

@test "shows an error state when the users collector fails" {
  write_response <<'EOF'
jellyfin_scrape_collector_success{collector="playing"} 1
jellyfin_scrape_collector_success{collector="users"} 0
jellyfin_up 1
EOF

  run env PATH="$tmpdir/bin:$PATH" bash "$plugin"

  [ "$status" -eq 0 ]
  [[ "$output" == *"label=?"* ]]
}

@test "shows an error state for an invalid playback sample" {
  write_response <<'EOF'
jellyfin_scrape_collector_success{collector="playing"} 1
jellyfin_scrape_collector_success{collector="users"} 1
jellyfin_up 1
jellyfin_now_playing_state{device="TV",title="Broken",type="Movie",user_id="one",username="One"} invalid
EOF

  run env PATH="$tmpdir/bin:$PATH" bash "$plugin"

  [ "$status" -eq 0 ]
  [[ "$output" == *"label=?"* ]]
}
