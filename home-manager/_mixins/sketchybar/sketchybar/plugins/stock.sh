#!/usr/bin/env bash

SYMBOL="${STOCK_SYMBOL:-NVDA}"
QUOTE_URL="https://api.nasdaq.com/api/quote/${SYMBOL}/info?assetclass=stocks"

format_price() {
  local price="$1"
  local prefix=""
  local numeric

  if [[ "$price" == \$* ]]; then
    prefix="$"
  fi

  numeric="${price//,/}"
  numeric="${numeric//\$/}"
  numeric="${numeric//[[:space:]]/}"

  if [[ "$numeric" =~ ^-?[0-9]+([.][0-9]+)?$ ]]; then
    printf '%s%.2f' "$prefix" "$numeric"
  else
    printf '%s' "$price"
  fi
}

if ! data="$(
  curl -fsSL \
    -H 'Accept: application/json' \
    -H 'User-Agent: Mozilla/5.0' \
    "$QUOTE_URL"
)"; then
  sketchybar --set "$NAME" icon="􀇿" icon.color="0xffe0af68" label="$SYMBOL"
  exit 0
fi

raw_last_price="$(jq -r '.data.primaryData.lastSalePrice // empty' <<<"$data" 2>/dev/null)"
direction="$(jq -r '.data.primaryData.deltaIndicator // empty' <<<"$data" 2>/dev/null)"

if [ -z "$raw_last_price" ]; then
  sketchybar --set "$NAME" icon="􀇿" icon.color="0xffe0af68" label="$SYMBOL"
  exit 0
fi

last_price="$(format_price "$raw_last_price")"

if [ "$direction" = "down" ]; then
	COLOR="0xffff0000"
	ICON="􀁩"
else
	COLOR="0xffa6e3a1"
	ICON="􀁧"
fi

sketchybar --set "$NAME" \
	icon="$ICON" \
	icon.color="$COLOR" \
	label="${last_price}"
