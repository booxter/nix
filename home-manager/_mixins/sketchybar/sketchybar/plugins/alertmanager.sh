#!/usr/bin/env bash

set -euo pipefail

RED="${SKETCHYBAR_COLOR_RED:-0xfffb4934}"
YELLOW="${SKETCHYBAR_COLOR_YELLOW:-0xfffabd2f}"

show_error() {
  sketchybar --set "$NAME" \
    drawing=on \
    icon="!" \
    icon.color="$YELLOW" \
    label="?" \
    label.color="$YELLOW"
}

if ! alerts="$(${CURL:-curl} \
  --fail \
  --silent \
  --show-error \
  --max-time 10 \
  --cacert "$ALERTMANAGER_CA_CERTIFICATE" \
  --cert "$ALERTMANAGER_CLIENT_CERTIFICATE" \
  --key "$ALERTMANAGER_CLIENT_KEY" \
  "${ALERTMANAGER_URL}?active=true&silenced=false&inhibited=false")"; then
  show_error
  exit 0
fi

if ! count="$(jq --exit-status 'if type == "array" then length else error("expected an array") end' <<<"$alerts" 2>/dev/null)"; then
  show_error
  exit 0
fi

if ((count == 0)); then
  sketchybar --set "$NAME" drawing=off
  exit 0
fi

sketchybar --set "$NAME" \
  drawing=on \
  icon="!" \
  icon.color="$RED" \
  label="$count" \
  label.color="$RED"
