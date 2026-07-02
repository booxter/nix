set -euo pipefail

delta="${1:?Usage: aerospace-x11-aware-resize +/-pixels}"
if [[ ! "$delta" =~ ^[+-][0-9]+$ ]]; then
  echo "Usage: aerospace-x11-aware-resize +/-pixels" >&2
  exit 64
fi

resize_aerospace() {
  exec aerospace resize smart "$delta"
}

frontmost_bundle_id="$(
  /usr/bin/osascript \
    -e 'tell application "System Events" to get bundle identifier of first application process whose frontmost is true' \
    2>/dev/null || true
)"

case "$frontmost_bundle_id" in
  org.nixos.xquartz.X11 | org.x.X11) ;;
  *) resize_aerospace ;;
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

resize_x11_display() {
  local display="$1"
  local active
  local height
  local new_height
  local new_width
  local width
  local window_info

  active="$(
    DISPLAY="$display" xprop -root _NET_ACTIVE_WINDOW 2>/dev/null \
      | awk -F'# ' '/# / { print $2; exit }'
  )"
  [ -n "$active" ] || return 1
  [ "$active" != "0x0" ] || return 1

  window_info="$(DISPLAY="$display" xwininfo -id "$active" 2>/dev/null)" || return 1
  width="$(printf '%s\n' "$window_info" | awk '/Width:/ { print $2; exit }')"
  height="$(printf '%s\n' "$window_info" | awk '/Height:/ { print $2; exit }')"
  [ -n "$width" ] && [ -n "$height" ] || return 1

  new_width=$((width + delta))
  new_height=$((height + delta))
  if [ "$new_width" -lt 50 ]; then
    new_width=50
  fi
  if [ "$new_height" -lt 50 ]; then
    new_height=50
  fi

  DISPLAY="$display" wmctrl -i -r "$active" -e "0,-1,-1,$new_width,$new_height"
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
  if resize_x11_display "$display"; then
    exit 0
  fi
done

echo "XQuartz is frontmost, but no active X11 window was found." >&2
exit 1
