#!/usr/bin/env bats

setup() {
  tmpdir="$(mktemp -d)"
  mkdir -p "$tmpdir/bin" "$tmpdir/home"
  plugin="${SKETCHYBAR_PLUGIN_DIR:-$BATS_TEST_DIRNAME/../plugins}/disk.sh"
  bash_path="$(command -v bash)"

  printf '#!%s\n' "$bash_path" >"$tmpdir/bin/df"
  cat >>"$tmpdir/bin/df" <<'EOF'
printf '%s\n' "$*" >"$DISK_TEST_DF_ARGS"
if [[ -n "${DISK_TEST_DF_FAILURE:-}" ]]; then
  exit 1
fi
cat "$DISK_TEST_DF_RESPONSE"
EOF

  printf '#!%s\n' "$bash_path" >"$tmpdir/bin/sketchybar"
  cat >>"$tmpdir/bin/sketchybar" <<'EOF'
printf '%s\n' "$*"
EOF
  chmod +x "$tmpdir/bin/df" "$tmpdir/bin/sketchybar"

  export NAME=disk
  export HOME="$tmpdir/home"
  export DISK_TEST_DF_ARGS="$tmpdir/df-args"
  export DISK_TEST_DF_RESPONSE="$tmpdir/df-response"
}

teardown() {
  rm -rf "$tmpdir"
}

write_df_response() {
  cat >"$DISK_TEST_DF_RESPONSE"
}

@test "shows the percentage of disk space remaining" {
  write_df_response <<'EOF'
Filesystem 1024-blocks Used Available Capacity Mounted on
/dev/disk 1000 750 250 75% /
EOF

  run env PATH="$tmpdir/bin:$PATH" bash "$plugin"

  [ "$status" -eq 0 ]
  [[ "$output" == *"--set disk label=25%"* ]]
  run grep -F -- "-Pk $HOME" "$DISK_TEST_DF_ARGS"
  [ "$status" -eq 0 ]
}

@test "rounds the remaining percentage down" {
  write_df_response <<'EOF'
Filesystem 1024-blocks Used Available Capacity Mounted on
/dev/disk 1000 831 169 84% /
EOF

  run env PATH="$tmpdir/bin:$PATH" bash "$plugin"

  [ "$status" -eq 0 ]
  [[ "$output" == *"label=16%"* ]]
}

@test "preserves the last value when disk usage is unavailable" {
  export DISK_TEST_DF_FAILURE=1

  run env PATH="$tmpdir/bin:$PATH" bash "$plugin"

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
