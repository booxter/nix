#!/usr/bin/env bash
set -euo pipefail

AUTH_FILE="${HOME}/.codex/auth.json"
ITEM="codex.work"
POPUP_CREDITS_ITEM="codex.work.credits"
POPUP_RESET_ITEM="codex.work.reset"

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

monthly_pace_risk_bps() {
  jq -r '
    if
      (.used_percent | type) != "number"
      or (.window_seconds | type) != "number"
      or (.elapsed_seconds | type) != "number"
      or .window_seconds <= 0
    then
      empty
    elif .used_percent <= 0 then
      0
    elif .elapsed_seconds <= 0 then
      empty
    else
      ((.used_percent * .window_seconds * 10 / .elapsed_seconds) | round)
    end
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
  local reached="$2"

  if [ "$reached" = "true" ]; then
    printf '%s' "$RED"
  elif [ -z "$risk_bps" ] || [ "$risk_bps" = "null" ]; then
    printf '%s' "$BLUE"
  else
    gradient_color "$risk_bps"
  fi
}

format_number() {
  local value="$1"

  if [ -z "$value" ] || [ "$value" = "null" ]; then
    printf '?'
  elif [[ "$value" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    printf '%s\n' "$value" | jq -r '
      if . >= 100 then
        round | tostring
      else
        ((. * 10 | round) / 10) | tostring
      end
    '
  else
    printf '%s' "$value"
  fi
}

case "${SENDER:-}" in
  mouse.entered)
    sketchybar --set "$ITEM" popup.drawing=on
    exit 0
    ;;
  mouse.exited | mouse.exited.global)
    sketchybar --set "$ITEM" popup.drawing=off
    exit 0
    ;;
esac

case "${NAME:-}" in
  "$POPUP_CREDITS_ITEM" | "$POPUP_RESET_ITEM")
    exit 0
    ;;
esac

hide_items() {
  sketchybar --set "$ITEM" drawing=off popup.drawing=off \
    --set "$POPUP_CREDITS_ITEM" drawing=off \
    --set "$POPUP_RESET_ITEM" drawing=off
}

if [ ! -f "$AUTH_FILE" ]; then
  hide_items
  exit 0
fi

if ! status="$(codex-work-usage-status --json 2>/dev/null)"; then
  sketchybar --set "$ITEM" \
    drawing=on \
    icon.drawing=off \
    label="work err" \
    label.color="$RED" \
    popup.drawing=off \
    --set "$POPUP_CREDITS_ITEM" drawing=off \
    --set "$POPUP_RESET_ITEM" drawing=off
  exit 0
fi

remaining_percent="$(jq -r '.remaining_percent // empty' <<<"$status")"
used_percent="$(jq -r '.used_percent // empty' <<<"$status")"
reached="$(jq -r '.reached // false' <<<"$status")"
limit="$(jq -r '.limit // empty' <<<"$status")"
used="$(jq -r '.used // empty' <<<"$status")"
remaining="$(jq -r '.remaining // empty' <<<"$status")"
reset_after="$(jq -r '.reset_after_seconds // empty' <<<"$status")"
reset_at="$(jq -r '.reset_at // empty' <<<"$status")"
pace_risk_bps="$(monthly_pace_risk_bps <<<"$status")"

label="work ${remaining_percent:-?}%"
color="$(pace_color "${pace_risk_bps:-}" "$reached")"
credits_label="$(printf 'credits: %s/%s left; used %s (%s%%)' \
  "$(format_number "$remaining")" \
  "$(format_number "$limit")" \
  "$(format_number "$used")" \
  "${used_percent:-?}")"

reset_text="$(format_duration "$reset_after")"
if reset_date="$(format_epoch_local "$reset_at")"; then
  reset_label="reset: ${reset_date} (${reset_text})"
else
  reset_label="reset: in ${reset_text}"
fi

if [ "$reached" = "true" ]; then
  credits_label="${credits_label}; limit reached"
fi

sketchybar --set "$ITEM" \
  drawing=on \
  label="$label" \
  label.color="$color" \
  popup.drawing=off \
  --set "$POPUP_CREDITS_ITEM" \
  drawing=on \
  label="$credits_label" \
  label.color="$NEUTRAL" \
  --set "$POPUP_RESET_ITEM" \
  drawing=on \
  label="$reset_label" \
  label.color="$NEUTRAL"
