#!/usr/bin/env bats

setup() {
  tmpdir="$(mktemp -d)"
  mkdir -p "$tmpdir/bin"
  plugin="${SKETCHYBAR_PLUGIN_DIR:-$BATS_TEST_DIRNAME/../plugins}/ip_address.sh"
  bash_path="$(command -v bash)"

  printf '#!%s\n' "$bash_path" >"$tmpdir/bin/scutil"
  cat >>"$tmpdir/bin/scutil" <<'EOF'
cat "$IP_ADDRESS_TEST_RESPONSE"
EOF

  printf '#!%s\n' "$bash_path" >"$tmpdir/bin/sketchybar"
  cat >>"$tmpdir/bin/sketchybar" <<'EOF'
printf '%s\n' "$*"
EOF
  chmod +x "$tmpdir/bin/scutil" "$tmpdir/bin/sketchybar"

  export NAME=ip_address
  export IP_ADDRESS_TEST_RESPONSE="$tmpdir/network-info"
  export SCUTIL="$tmpdir/bin/scutil"
  unset SENDER
}

teardown() {
  rm -rf "$tmpdir"
}

write_response() {
  cat >"$IP_ADDRESS_TEST_RESPONSE"
}

@test "updates the hidden network label with the current address" {
  write_response <<'EOF'
Network interfaces: en0
   address : 192.168.1.20
EOF

  run env PATH="$tmpdir/bin:$PATH" bash "$plugin"

  [ "$status" -eq 0 ]
  [[ "$output" == *"--set ip_address"* ]]
  [[ "$output" == *"label=192.168.1.20"* ]]
  [[ "$output" != *"label.drawing="* ]]
}

@test "toggles the address label when clicked" {
  write_response <<'EOF'
Network interfaces: en0
   address : 192.168.1.20
EOF

  run env PATH="$tmpdir/bin:$PATH" SENDER=mouse.clicked bash "$plugin"

  [ "$status" -eq 0 ]
  [[ "$output" == *"label=192.168.1.20"* ]]
  [[ "$output" == *"label.drawing=toggle"* ]]
}

@test "shows the VPN address when the VPN icon is clicked" {
  write_response <<'EOF'
Network interfaces: utun4 en0
utun4 : flags      : 0x5 (IPv4,DNS)
   address : 100.64.0.2
   address : 192.168.1.20
EOF

  run env PATH="$tmpdir/bin:$PATH" SENDER=mouse.clicked bash "$plugin"

  [ "$status" -eq 0 ]
  [[ "$output" == *"label=100.64.0.2"* ]]
  [[ "$output" != *"label=VPN"* ]]
  [[ "$output" == *"label.drawing=toggle"* ]]
}

@test "keeps the disconnected state available on click" {
  write_response <<'EOF'
Network interfaces: no network interfaces
EOF

  run env PATH="$tmpdir/bin:$PATH" SENDER=mouse.clicked bash "$plugin"

  [ "$status" -eq 0 ]
  [[ "$output" == *"label=Not Connected"* ]]
  [[ "$output" == *"label.drawing=toggle"* ]]
}
