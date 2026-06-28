#!/usr/bin/env bash
set -euo pipefail

AUTH_FILE="${HOME}/.codex/auth.json"

GREEN="0xff9ece6a"
YELLOW="0xffe0af68"
ORANGE="0xffff9e64"
RED="0xfff7768e"
BLUE="0xff7aa2f7"

format_duration() {
  local seconds="$1"

  if [ -z "$seconds" ] || [ "$seconds" = "null" ]; then
    printf '?'
    return
  fi

  if [ "$seconds" -lt 60 ]; then
    printf '%ss' "$seconds"
  elif [ "$seconds" -lt 3600 ]; then
    printf '%sm' "$((seconds / 60))"
  elif [ "$seconds" -lt 86400 ]; then
    printf '%sh%02d' "$((seconds / 3600))" "$(((seconds % 3600) / 60))"
  else
    printf '%sd%02dh' "$((seconds / 86400))" "$(((seconds % 86400) / 3600))"
  fi
}

remaining_color() {
  local remaining="$1"
  local limit_reached="$2"

  if [ "$limit_reached" = "true" ]; then
    printf '%s' "$RED"
  elif [ -z "$remaining" ] || [ "$remaining" = "null" ]; then
    printf '%s' "$BLUE"
  elif [ "$remaining" -le 5 ]; then
    printf '%s' "$RED"
  elif [ "$remaining" -le 20 ]; then
    printf '%s' "$ORANGE"
  elif [ "$remaining" -le 35 ]; then
    printf '%s' "$YELLOW"
  else
    printf '%s' "$GREEN"
  fi
}

if [ ! -f "$AUTH_FILE" ]; then
  sketchybar --set "$NAME" drawing=off
  exit 0
fi

if ! status="$(codex-usage-status --json 2>/dev/null)"; then
  sketchybar --set "$NAME" \
    drawing=on \
    icon.drawing=off \
    label="err" \
    label.color="$RED"
  exit 0
fi

limit_reached="$(jq -r '.limit_reached // false' <<<"$status")"
five_remaining="$(jq -r '.windows.five_hour.remaining_percent // empty' <<<"$status")"
week_remaining="$(jq -r '.windows.weekly.remaining_percent // empty' <<<"$status")"
five_reset="$(jq -r '.windows.five_hour.reset_after_seconds // empty' <<<"$status")"
week_reset="$(jq -r '.windows.weekly.reset_after_seconds // empty' <<<"$status")"
refreshes="$(jq -r '.rate_limit_reset_credits.available_count // 0' <<<"$status")"
color_remaining="$(jq -r '[.windows.five_hour.remaining_percent, .windows.weekly.remaining_percent] | map(select(. != null)) | min // empty' <<<"$status")"

five_reset_label="$(format_duration "$five_reset")"
week_reset_label="$(format_duration "$week_reset")"

label="${five_remaining:-?}%/${five_reset_label} ${week_remaining:-?}%/${week_reset_label} +${refreshes}"
color="$(remaining_color "${color_remaining:-}" "$limit_reached")"

sketchybar --set "$NAME" \
  drawing=on \
  icon.drawing=off \
  label="$label" \
  label.color="$color"
