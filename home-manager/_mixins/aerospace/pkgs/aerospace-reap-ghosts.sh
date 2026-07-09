#!/usr/bin/env bash
set -euo pipefail

# Work around stale windows tracked in:
# https://github.com/nikitabobko/AeroSpace/issues/1615
# This uses the guarded workspace-switch reaper suggested in:
# https://github.com/nikitabobko/AeroSpace/issues/1615#issuecomment-4667204873

state_dir="${XDG_CACHE_HOME:-$HOME/.cache}/aerospace"
state="$state_dir/ghost-prev"
lock_dir="$state_dir/ghost-reaper.lock"

mkdir -p "$state_dir"

# Workspace switches can happen close together. Let only one background reaper
# update the debounce state at a time.
if ! mkdir "$lock_dir" 2>/dev/null; then
  exit 0
fi
trap 'rmdir "$lock_dir"' EXIT

empties="$(
  aerospace list-windows --all --json 2>/dev/null \
    | jq -r '.[] | select(."window-title" == "") | ."window-id"' \
    | sort -nu
)"
prev="$(cat "$state" 2>/dev/null || true)"

# A window becomes eligible only if it remains titleless across two workspace
# changes. This filters out newly opened windows before their title appears.
printf '%s\n' "$empties" >"$state"

focused="$(
  aerospace list-windows --focused --format '%{window-id}' 2>/dev/null \
    | tr -d '[:space:]' \
    || true
)"

comm -12 \
  <(printf '%s\n' "$empties") \
  <(printf '%s\n' "$prev" | sort -nu) \
  | while IFS= read -r id; do
    [ -n "$id" ] || continue
    [ "$id" != "$focused" ] || continue
    aerospace close --window-id "$id" 2>/dev/null || true
  done
