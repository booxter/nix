#!/usr/bin/env bash

set -euo pipefail

show_error() {
  sketchybar --set "$NAME" \
    drawing=on \
    icon="!" \
    icon.color="0xffe0af68" \
    label="?" \
    label.color="0xffe0af68"
}

if ! metrics="$(${CURL:-curl} \
  --fail \
  --silent \
  --show-error \
  --max-time 10 \
  --cacert "$JELLYFIN_CA_CERTIFICATE" \
  --cert "$JELLYFIN_CLIENT_CERTIFICATE" \
  --key "$JELLYFIN_CLIENT_KEY" \
  "$JELLYFIN_METRICS_URL")"; then
  show_error
  exit 0
fi

if ! count="$(awk '
  function sample_value(line, value) {
    value = line
    sub(/^.*}[[:space:]]+/, "", value)
    sub(/[[:space:]].*$/, "", value)
    return value
  }

  BEGIN {
    jellyfin_up = -1
    playing_collector_up = -1
    streams = 0
    invalid = 0
  }

  /^jellyfin_up[[:space:]]+/ {
    jellyfin_up = $2
    next
  }

  /^jellyfin_scrape_collector_success\{collector="playing"\}[[:space:]]+/ {
    playing_collector_up = sample_value($0)
    next
  }

  /^jellyfin_now_playing_state\{/ {
    if ($0 !~ /type="(Audio|AudioBook|Episode|Movie|MusicVideo|Trailer|Video)"/) {
      next
    }

    value = sample_value($0)
    if (value !~ /^[-+]?([0-9]+([.][0-9]*)?|[.][0-9]+)([eE][-+]?[0-9]+)?$/) {
      invalid = 1
      next
    }
    if (value > 0.5) {
      streams++
    }
  }

  END {
    if (invalid || jellyfin_up != 1 || playing_collector_up != 1) {
      exit 1
    }
    print streams
  }
' <<<"$metrics")"; then
  show_error
  exit 0
fi

if ((count == 0)); then
  sketchybar --set "$NAME" drawing=off
  exit 0
fi

sketchybar --set "$NAME" \
  drawing=on \
  icon="󰼁" \
  icon.color="0xffaa5cc3" \
  label="$count" \
  label.color="0xffaa5cc3"
