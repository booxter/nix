#!/usr/bin/env bash
set -euo pipefail

direction="${1:?Usage: aerospace-x11-aware-move left|down|up|right}"
case "$direction" in
  left | down | up | right) ;;
  *)
    echo "Usage: aerospace-x11-aware-move left|down|up|right" >&2
    exit 64
    ;;
esac

move_aerospace() {
  exec aerospace move "$direction"
}

frontmost_bundle_id() {
  local asn
  local bundle_id

  asn="$(
    /usr/bin/lsappinfo visibleProcessList 2>/dev/null \
      | awk 'match($0, /ASN:0x[[:xdigit:]]+-0x[[:xdigit:]]+/) { print substr($0, RSTART, RLENGTH) ":"; exit }'
  )"
  if [ -n "$asn" ]; then
    bundle_id="$(
      /usr/bin/lsappinfo info -only bundleid "$asn" 2>/dev/null \
        | awk -F'"' '/CFBundleIdentifier/ { print $4; exit }'
    )"
    if [ -n "$bundle_id" ]; then
      printf '%s\n' "$bundle_id"
      return 0
    fi
  fi

  /usr/bin/osascript \
    -e 'tell application "System Events" to get bundle identifier of first application process whose frontmost is true' \
    2>/dev/null || true
}

frontmost_bundle_id="$(frontmost_bundle_id)"

case "$frontmost_bundle_id" in
  org.nixos.xquartz.X11 | org.x.X11) ;;
  "")
    echo "Could not determine the frontmost macOS app; refusing to move a background AeroSpace window." >&2
    exit 1
    ;;
  *) move_aerospace ;;
esac

displays=()

add_display() {
  local display="$1"
  local existing

  [ -n "$display" ] || return 0
  for existing in "${displays[@]}"; do
    [ "$existing" != "$display" ] || return 0
  done
  displays+=("$display")
}

move_x11_display() {
  local active
  local display="$1"
  local x
  local y
  local window_info

  active="$(
    DISPLAY="$display" xprop -root _NET_ACTIVE_WINDOW 2>/dev/null \
      | awk -F'# ' '/# / { print $2; exit }'
  )"
  [ -n "$active" ] || return 1
  [ "$active" != "0x0" ] || return 1

  window_info="$(DISPLAY="$display" xwininfo -id "$active" 2>/dev/null)" || return 1
  x="$(printf '%s\n' "$window_info" | awk '/Absolute upper-left X:/ { print $4; exit }')"
  y="$(printf '%s\n' "$window_info" | awk '/Absolute upper-left Y:/ { print $4; exit }')"
  [ -n "$x" ] && [ -n "$y" ] || return 1

  case "$direction" in
    left) x=$((x - 50)) ;;
    right) x=$((x + 50)) ;;
    up) y=$((y - 50)) ;;
    down) y=$((y + 50)) ;;
  esac

  if [ "$x" -lt 0 ]; then
    x=0
  fi
  if [ "$y" -lt 0 ]; then
    y=0
  fi

  DISPLAY="$display" wmctrl -i -r "$active" -e "0,$x,$y,-1,-1"
}

add_display "${XQUARTZ_DISPLAY:-}"
add_display "${DISPLAY:-}"
for socket in /tmp/.X11-unix/X* /private/tmp/.X11-unix/X*; do
  [ -e "$socket" ] || continue
  add_display ":${socket##*X}"
done
for display_number in 0 1 2 3 4 5 6 7 8 9; do
  add_display ":$display_number"
done

for display in "${displays[@]}"; do
  if move_x11_display "$display"; then
    exit 0
  fi
done

echo "XQuartz is frontmost, but no active X11 window was found." >&2
exit 1
