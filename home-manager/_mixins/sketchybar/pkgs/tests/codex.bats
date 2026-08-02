#!/usr/bin/env bats

setup() {
  tmpdir="$(mktemp -d)"
  mkdir -p "$tmpdir/bin" "$tmpdir/home/.codex"
  plugin="${SKETCHYBAR_PLUGIN_DIR:-$BATS_TEST_DIRNAME/../plugins}/codex.sh"
  bash_path="$(command -v bash)"

  printf '%s\n' '{}' >"$tmpdir/home/.codex/auth.json"

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

  printf '#!%s\n' "$bash_path" >"$tmpdir/bin/sketchybar"
  cat >>"$tmpdir/bin/sketchybar" <<'EOF'
printf '%s\n' "$@"
EOF
  chmod +x "$tmpdir/bin/codex-usage-status" "$tmpdir/bin/sketchybar"
}

teardown() {
  rm -rf "$tmpdir"
}

@test "renders an unavailable window with a compact placeholder" {
  run env HOME="$tmpdir/home" PATH="$tmpdir/bin:$PATH" NAME=codex.5h bash "$plugin"

  [ "$status" -eq 0 ]
  [[ "$output" == *"label=5h ???"* ]]
  [[ "$output" == *"label=1w 96%/6d19h"* ]]
  [[ "$output" != *"?%/?"* ]]
}
