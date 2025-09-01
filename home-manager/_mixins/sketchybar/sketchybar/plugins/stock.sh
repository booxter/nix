#!/usr/bin/env bash

data=$(curl -s https://groww.in/us-stocks/nvda)

lastPrice=$(echo $data | grep -oP '"lastPrice":\K[0-9.]*')
openingPrice=$(echo $data | grep -oP '"openingPrice":\K[0-9.]*')

if (( $(echo "$lastPrice < $openingPrice" | bc -l) )); then
	COLOR="0xffff0000"
	ICON="􀁩"
else
	COLOR="0xffa6e3a1"
	ICON="􀁧"
fi

sketchybar --set $NAME \
	icon=$ICON  \
	icon.color=$COLOR \
	label="${lastPrice}"
