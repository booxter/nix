#!/usr/bin/env bash

price=$(curl https://groww.in/us-stocks/nvda | grep -oP '"lastPrice":\K[0-9.]*')

sketchybar --set $NAME \
	icon=􀖘  \
	label="${price}"
