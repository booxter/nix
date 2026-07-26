#!/usr/bin/env bats

setup() {
  export TEST_ROOT="$BATS_TEST_TMPDIR/root"
  mkdir -p "$TEST_ROOT"
  SOCKET_PID=""
}

teardown() {
  if [[ -n "$SOCKET_PID" ]]; then
    kill "$SOCKET_PID" 2>/dev/null || true
  fi
}

run_nixpkgs() {
  "$RUN_NIXPKGS_BIN" "$@"
}

start_wayland_socket() {
  local socket_path="$1"

  python3 -c '
import socket
import sys
import time

listener = socket.socket(socket.AF_UNIX)
listener.bind(sys.argv[1])
time.sleep(60)
' "$socket_path" &
  SOCKET_PID=$!

  for _ in {1..100}; do
    [[ -S "$socket_path" ]] && return 0
    sleep 0.01
  done
  return 1
}

@test "dry-run resolves nixpkgs pull request shortcuts" {
  run run_nixpkgs --dry-run 538891 foot

  [ "$status" -eq 0 ]
  [[ "$output" == *"ssh host: frame"* ]]
  [[ "$output" == *"transport: $RUN_NIXPKGS_TEST_TRANSPORT"* ]]
  [[ "$output" == *"installable: github:NixOS/nixpkgs?ref=pull/538891/head#foot"* ]]
}

@test "X11 runner retains trusted forwarding" {
  [[ "$RUN_NIXPKGS_TEST_TRANSPORT" == x11 ]] || skip

  run run_nixpkgs --trusted --dry-run nixpkgs foot

  [ "$status" -eq 0 ]
  [[ "$output" == *"x11 forwarding: -Y"* ]]
}

@test "Waypipe runner rejects X11-only options" {
  [[ "$RUN_NIXPKGS_TEST_TRANSPORT" == waypipe ]] || skip

  run run_nixpkgs --trusted --dry-run nixpkgs foot

  [ "$status" -eq 64 ]
  [[ "$output" == *"--trusted is only available for X11 forwarding"* ]]
}

@test "Waypipe runner requires a Cocoa-Way socket" {
  [[ "$RUN_NIXPKGS_TEST_TRANSPORT" == waypipe ]] || skip
  export COCOA_WAY_RUNTIME_DIR="$TEST_ROOT/missing"
  export TMPDIR="$TEST_ROOT/missing-tmp"
  unset XDG_RUNTIME_DIR WAYLAND_DISPLAY

  run run_nixpkgs nixpkgs foot

  [ "$status" -eq 1 ]
  [[ "$output" == *"Unable to find a live Cocoa-Way socket"* ]]
  [[ "$output" == *"COCOA_WAY_PRESENTATION=rootless cocoa-way"* ]]
}

@test "Waypipe runner discovers Cocoa-Way and invokes the remote wrapper" {
  [[ "$RUN_NIXPKGS_TEST_TRANSPORT" == waypipe ]] || skip
  mkdir -p "$TEST_ROOT/runtime"
  start_wayland_socket "$TEST_ROOT/runtime/wayland-7"

  export COCOA_WAY_RUNTIME_DIR="$TEST_ROOT/runtime"
  export WAYPIPE_LOG="$TEST_ROOT/waypipe.log"
  export WAYLAND_LOG="$TEST_ROOT/wayland.log"
  export WRUN_NIXPKGS_WAYPIPE="$RUN_NIXPKGS_WAYPIPE_STUB"
  unset XDG_RUNTIME_DIR WAYLAND_DISPLAY

  run run_nixpkgs \
    --ssh-option ServerAliveInterval=10 \
    538891 foot -- --title smoke-test

  [ "$status" -eq 0 ]
  [ "$(cat "$WAYLAND_LOG")" = "$TEST_ROOT/runtime/wayland-7" ]
  grep -Fq -- \
    "--no-gpu --compress=zstd --remote-bin waypipe ssh -o StreamLocalBindUnlink=yes -o ServerAliveInterval=10 frame" \
    "$WAYPIPE_LOG"
  grep -Fq "github:NixOS/nixpkgs?ref=pull/538891/head" "$WAYPIPE_LOG"
  grep -Fq "smoke-test" "$WAYPIPE_LOG"
}
