#!/usr/bin/env bash
set -euo pipefail

AUTH_FILE="${HOME}/.codex/auth.json"
FIVE_HOUR_ITEM="codex.5h"
WEEKLY_ITEM="codex.weekly"
RESETS_ITEM="codex.resets"
RESETS_POPUP_ITEM="codex.resets.expiry"
EXPIRING_RESET_SECONDS=604800

GREEN="0xff9ece6a"
RED="0xfff7768e"
BLUE="0xff7aa2f7"
NEUTRAL="0xffa9b1d6"

format_duration() {
  local seconds="$1"

  if [ -z "$seconds" ] || [ "$seconds" = "null" ]; then
    printf '?'
    return
  fi
  if ! [[ "$seconds" =~ ^-?[0-9]+$ ]]; then
    printf '?'
    return
  fi

  if [ "$seconds" -lt 0 ]; then
    printf 'expired'
  elif [ "$seconds" -lt 60 ]; then
    printf '%ss' "$seconds"
  elif [ "$seconds" -lt 3600 ]; then
    printf '%sm' "$((seconds / 60))"
  elif [ "$seconds" -lt 86400 ]; then
    printf '%sh%02d' "$((seconds / 3600))" "$(((seconds % 3600) / 60))"
  else
    printf '%sd%02dh' "$((seconds / 86400))" "$(((seconds % 86400) / 3600))"
  fi
}

format_epoch_local() {
  local epoch="$1"

  if ! [[ "$epoch" =~ ^[0-9]+$ ]]; then
    return 1
  fi

  if date -r "$epoch" '+%Y-%m-%d %H:%M %Z' >/dev/null 2>&1; then
    date -r "$epoch" '+%Y-%m-%d %H:%M %Z'
  elif date -d "@$epoch" '+%Y-%m-%d %H:%M %Z' >/dev/null 2>&1; then
    date -d "@$epoch" '+%Y-%m-%d %H:%M %Z'
  else
    return 1
  fi
}

window_pace_risk_bps() {
  local window="$1"

  jq -r --arg window "$window" '
    def risk_bps($window):
      if
        $window == null
        or ($window.used_percent | type) != "number"
        or ($window.limit_window_seconds | type) != "number"
        or ($window.reset_after_seconds | type) != "number"
        or $window.limit_window_seconds <= 0
      then
        null
      else
        ($window.limit_window_seconds - $window.reset_after_seconds) as $elapsed
        | if $window.used_percent <= 0 then
            0
          elif $elapsed <= 0 then
            null
          else
            (($window.used_percent * $window.limit_window_seconds * 10 / $elapsed) | round)
          end
      end;

    risk_bps(.windows[$window]) // empty
  '
}

mix_channel() {
  local start="$1"
  local end="$2"
  local numerator="$3"
  local denominator="$4"

  printf '%d' "$(((start * (denominator - numerator) + end * numerator + denominator / 2) / denominator))"
}

gradient_color() {
  local risk_bps="$1"
  local from_r from_g from_b to_r to_g to_b start end

  if ! [[ "$risk_bps" =~ ^[0-9]+$ ]]; then
    printf '%s' "$BLUE"
    return
  fi

  if [ "$risk_bps" -le 1000 ]; then
    printf '%s' "$GREEN"
    return
  elif [ "$risk_bps" -le 1100 ]; then
    start=1000
    end=1100
    from_r=0x9e
    from_g=0xce
    from_b=0x6a
    to_r=0xe0
    to_g=0xaf
    to_b=0x68
  elif [ "$risk_bps" -le 1250 ]; then
    start=1100
    end=1250
    from_r=0xe0
    from_g=0xaf
    from_b=0x68
    to_r=0xff
    to_g=0x9e
    to_b=0x64
  elif [ "$risk_bps" -le 1500 ]; then
    start=1250
    end=1500
    from_r=0xff
    from_g=0x9e
    from_b=0x64
    to_r=0xf7
    to_g=0x76
    to_b=0x8e
  else
    printf '%s' "$RED"
    return
  fi

  local numerator=$((risk_bps - start))
  local denominator=$((end - start))
  local r g b
  r="$(mix_channel "$from_r" "$to_r" "$numerator" "$denominator")"
  g="$(mix_channel "$from_g" "$to_g" "$numerator" "$denominator")"
  b="$(mix_channel "$from_b" "$to_b" "$numerator" "$denominator")"

  printf '0xff%02x%02x%02x' "$r" "$g" "$b"
}

pace_color() {
  local risk_bps="$1"
  local window_limit_reached="$2"

  if [ "$window_limit_reached" = "true" ]; then
    printf '%s' "$RED"
  elif [ -z "$risk_bps" ] || [ "$risk_bps" = "null" ]; then
    printf '%s' "$BLUE"
  else
    gradient_color "$risk_bps"
  fi
}

window_limit_reached() {
  local window="$1"
  local limit_reached="$2"
  local limit_reached_type="$3"

  if [ "$limit_reached" != "true" ]; then
    printf 'false'
    return
  fi

  case "$window:$limit_reached_type" in
    five_hour:primary | five_hour:primary_window | five_hour:five_hour | weekly:secondary | weekly:secondary_window | weekly:weekly)
      printf 'true'
      ;;
    *:all | *:both | *:null | *:)
      printf 'true'
      ;;
    *)
      printf 'false'
      ;;
  esac
}

reset_count_label() {
  local reset_count="$1"

  if [ "$reset_count" = "1" ]; then
    printf '1 reset'
  else
    printf '%s resets' "$reset_count"
  fi
}

reset_color() {
  local reset_count="$1"
  local next_expires_after_seconds="$2"

  if ! [[ "$reset_count" =~ ^[0-9]+$ ]] || [ "$reset_count" -le 0 ]; then
    printf '%s' "$NEUTRAL"
  elif [[ "$next_expires_after_seconds" =~ ^-?[0-9]+$ ]] \
    && [ "$next_expires_after_seconds" -le "$EXPIRING_RESET_SECONDS" ]; then
    printf '%s' "$RED"
  else
    printf '%s' "$GREEN"
  fi
}

reset_tooltip() {
  local reset_count="$1"
  local next_expires_at="$2"
  local next_expires_at_unix="$3"
  local next_expires_after_seconds="$4"
  local reset_count_text expires_text remaining_text

  if ! [[ "$reset_count" =~ ^[0-9]+$ ]] || [ "$reset_count" -le 0 ]; then
    printf 'No rate-limit reset credits available'
    return
  fi

  reset_count_text="$(reset_count_label "$reset_count")"
  if [[ "$next_expires_after_seconds" =~ ^-?[0-9]+$ ]]; then
    remaining_text="$(format_duration "$next_expires_after_seconds")"
  else
    remaining_text='?'
  fi

  if expires_text="$(format_epoch_local "$next_expires_at_unix")"; then
    :
  elif [ -n "$next_expires_at" ] && [ "$next_expires_at" != "null" ]; then
    expires_text="$next_expires_at"
  else
    printf '%s available; expiry unavailable' "$reset_count_text"
    return
  fi

  printf '%s available; nearest expires %s (%s)' "$reset_count_text" "$expires_text" "$remaining_text"
}

case "${SENDER:-}" in
  mouse.entered)
    sketchybar --set "$RESETS_ITEM" popup.drawing=on
    exit 0
    ;;
  mouse.exited | mouse.exited.global)
    sketchybar --set "$RESETS_ITEM" popup.drawing=off
    exit 0
    ;;
esac

if [ "${NAME:-}" = "$RESETS_ITEM" ]; then
  exit 0
fi

hide_items() {
  sketchybar --set "$FIVE_HOUR_ITEM" drawing=off \
    --set "$WEEKLY_ITEM" drawing=off \
    --set "$RESETS_ITEM" drawing=off popup.drawing=off \
    --set "$RESETS_POPUP_ITEM" drawing=off
}

if [ ! -f "$AUTH_FILE" ]; then
  hide_items
  exit 0
fi

if ! status="$(codex-usage-status --json 2>/dev/null)"; then
  sketchybar --set "$FIVE_HOUR_ITEM" \
    drawing=on \
    icon.drawing=off \
    label="err" \
    label.color="$RED" \
    --set "$WEEKLY_ITEM" drawing=off \
    --set "$RESETS_ITEM" drawing=off popup.drawing=off \
    --set "$RESETS_POPUP_ITEM" drawing=off
  exit 0
fi

limit_reached="$(jq -r '.limit_reached // false' <<<"$status")"
limit_reached_type="$(jq -r '.limit_reached_type // empty' <<<"$status")"
five_remaining="$(jq -r '.windows.five_hour.remaining_percent // empty' <<<"$status")"
week_remaining="$(jq -r '.windows.weekly.remaining_percent // empty' <<<"$status")"
five_reset="$(jq -r '.windows.five_hour.reset_after_seconds // empty' <<<"$status")"
week_reset="$(jq -r '.windows.weekly.reset_after_seconds // empty' <<<"$status")"
refreshes="$(jq -r '.rate_limit_reset_credits.available_count // 0' <<<"$status")"
next_reset_expires_at="$(jq -r '.rate_limit_reset_credits.next_expires_at // empty' <<<"$status")"
next_reset_expires_at_unix="$(jq -r '.rate_limit_reset_credits.next_expires_at_unix // empty' <<<"$status")"
next_reset_expires_after="$(jq -r '.rate_limit_reset_credits.next_expires_after_seconds // empty' <<<"$status")"
five_pace_risk_bps="$(window_pace_risk_bps five_hour <<<"$status")"
week_pace_risk_bps="$(window_pace_risk_bps weekly <<<"$status")"
five_limit_reached="$(window_limit_reached five_hour "$limit_reached" "$limit_reached_type")"
week_limit_reached="$(window_limit_reached weekly "$limit_reached" "$limit_reached_type")"

five_reset_label="$(format_duration "$five_reset")"
week_reset_label="$(format_duration "$week_reset")"

five_label="5h ${five_remaining:-?}%/${five_reset_label}"
week_label="1w ${week_remaining:-?}%/${week_reset_label}"
reset_label="+${refreshes}"
five_color="$(pace_color "${five_pace_risk_bps:-}" "$five_limit_reached")"
week_color="$(pace_color "${week_pace_risk_bps:-}" "$week_limit_reached")"
refreshes_color="$(reset_color "$refreshes" "$next_reset_expires_after")"
refreshes_tooltip="$(
  reset_tooltip "$refreshes" "$next_reset_expires_at" "$next_reset_expires_at_unix" "$next_reset_expires_after"
)"

sketchybar --set "$FIVE_HOUR_ITEM" \
  drawing=on \
  label="$five_label" \
  label.color="$five_color" \
  --set "$WEEKLY_ITEM" \
  drawing=on \
  label="$week_label" \
  label.color="$week_color" \
  --set "$RESETS_ITEM" \
  drawing=on \
  label="$reset_label" \
  label.color="$refreshes_color" \
  popup.drawing=off \
  --set "$RESETS_POPUP_ITEM" \
  drawing=on \
  label="$refreshes_tooltip" \
  label.color="$refreshes_color"
