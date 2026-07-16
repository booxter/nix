#!/usr/bin/env bash

set -euo pipefail

if ! summary="$(${CURL:-curl} \
  --fail \
  --silent \
  --show-error \
  --max-time 10 \
  "$GITHUB_STATUS_URL")"; then
  exit 0
fi

if ! has_issues="$(jq --raw-output '
  if (.status.indicator | type) != "string"
    or (.components | type) != "array"
    or (.incidents | type) != "array"
  then
    error("unexpected GitHub Status response")
  else
    .status.indicator != "none"
      or any(.components[]; .status != "operational")
      or (.incidents | length > 0)
  end
' <<<"$summary" 2>/dev/null)"; then
  exit 0
fi

if [[ "$has_issues" == "false" ]]; then
  sketchybar --set "$NAME" drawing=off
  exit 0
fi

sketchybar --set "$NAME" \
  drawing=on \
  icon="" \
  icon.color="0xfff7768e" \
  label.drawing=off
