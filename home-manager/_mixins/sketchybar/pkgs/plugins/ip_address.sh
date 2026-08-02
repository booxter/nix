#!/usr/bin/env bash

network_info="$(${SCUTIL:-scutil} --nwi 2>/dev/null || true)"
ip_address="$(awk '
  /address/ {
    sub(/.*:/, "")
    gsub(/[[:space:]]/, "")
    print
    exit
  }
' <<<"$network_info")"
is_vpn="$(awk '/utun/ { print $1; exit }' <<<"$network_info")"

if [[ -n "$is_vpn" ]]; then
	ICON=􀎠
	LABEL="${ip_address:-VPN}"
elif [[ -n "$ip_address" ]]; then
	ICON=􀙇
	LABEL="$ip_address"
else
	ICON=􀇿
	LABEL="Not Connected"
fi

args=(
  --set "$NAME"
  icon="$ICON"
  label="$LABEL"
)
if [[ "${SENDER:-}" == "mouse.clicked" ]]; then
  args+=(label.drawing=toggle)
fi

sketchybar "${args[@]}"
