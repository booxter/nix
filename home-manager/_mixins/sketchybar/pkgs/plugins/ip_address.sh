#!/usr/bin/env bash

IP_ADDRESS=$(scutil --nwi | grep address | sed 's/.*://' | tr -d ' ' | head -1)
IS_VPN=$(scutil --nwi | grep -m1 'utun' | awk '{ print $1 }')

if [[ -n "$IS_VPN" ]]; then
	ICON=􀎠
	LABEL="VPN"
elif [[ -n "$IP_ADDRESS" ]]; then
	ICON=􀙇
	LABEL="$IP_ADDRESS"
else
	ICON=􀇿
	LABEL="Not Connected"
fi

sketchybar --set "$NAME" \
	icon="$ICON" \
	label="$LABEL"
