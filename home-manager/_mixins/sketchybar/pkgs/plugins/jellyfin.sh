#!/usr/bin/env bash

set -euo pipefail

PURPLE="${SKETCHYBAR_COLOR_PURPLE:-0xffd3869b}"
YELLOW="${SKETCHYBAR_COLOR_YELLOW:-0xfffabd2f}"
MAX_POPUP_SESSIONS=8

hide_popup_rows() {
  local index

  for ((index = 0; index < MAX_POPUP_SESSIONS; index++)); do
    sketchybar --set "$NAME.session.$index" drawing=off
  done
}

show_error() {
  hide_popup_rows
  sketchybar --set "$NAME" \
    drawing=on \
    popup.drawing=off \
    icon="!" \
    icon.color="$YELLOW" \
    label="?" \
    label.color="$YELLOW"
}

format_remaining() {
  local hours minutes seconds="$1"

  if ((seconds < 60)); then
    printf '<1m left'
    return
  fi

  minutes=$(((seconds + 59) / 60))
  if ((minutes < 60)); then
    printf '%dm left' "$minutes"
    return
  fi

  hours=$((minutes / 60))
  minutes=$((minutes % 60))
  if ((minutes == 0)); then
    printf '%dh left' "$hours"
  else
    printf '%dh %02dm left' "$hours" "$minutes"
  fi
}

episode_code() {
  local code="" episode="$2" season="$1"

  if [[ -n "$season" ]]; then
    if [[ "$season" == S* || "$season" == s* ]]; then
      code="$season"
    else
      code="S$season"
    fi
  fi
  if [[ -n "$episode" ]]; then
    if [[ "$episode" == E* || "$episode" == e* ]]; then
      code="$code$episode"
    else
      code="${code}E$episode"
    fi
  fi
  printf '%s' "$code"
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

if ! sessions="$(awk '
  function sample_value(line, value) {
    value = line
    sub(/^.*}[[:space:]]+/, "", value)
    sub(/[[:space:]].*$/, "", value)
    return value
  }

  function is_number(value) {
    return value ~ /^[-+]?([0-9]+([.][0-9]*)?|[.][0-9]+)([eE][-+]?[0-9]+)?$/
  }

  function label_value(line, name, rest, result, character, escaped, cursor) {
    if (!match(line, "(^|[,{])" name "=\"")) {
      return ""
    }

    rest = substr(line, RSTART + RLENGTH)
    result = ""
    escaped = 0
    for (cursor = 1; cursor <= length(rest); cursor++) {
      character = substr(rest, cursor, 1)
      if (escaped) {
        if (character == "n" || character == "t" || character == "r") {
          result = result " "
        } else {
          result = result character
        }
        escaped = 0
      } else if (character == "\\") {
        escaped = 1
      } else if (character == "\"") {
        break
      } else {
        result = result character
      }
    }
    gsub(/[[:cntrl:]]+/, " ", result)
    return result
  }

  function session_key(line) {
    return label_value(line, "user_id") SUBSEP \
      label_value(line, "username") SUBSEP \
      label_value(line, "device") SUBSEP \
      label_value(line, "type") SUBSEP \
      label_value(line, "title") SUBSEP \
      label_value(line, "series_title") SUBSEP \
      label_value(line, "series_season") SUBSEP \
      label_value(line, "series_episode") SUBSEP \
      label_value(line, "method")
  }

  function user_key(line) {
    return label_value(line, "user_id") SUBSEP \
      label_value(line, "username") SUBSEP \
      label_value(line, "device")
  }

  function ip_scope(endpoint, ip, octets, count) {
    ip = tolower(endpoint)
    if (ip == "") {
      return "unknown"
    }
    if (ip ~ /^\[[^]]+\](:[0-9]+)?$/) {
      sub(/^\[/, "", ip)
      sub(/\](:[0-9]+)?$/, "", ip)
    } else if (ip ~ /^[0-9.]+:[0-9]+$/) {
      sub(/:[0-9]+$/, "", ip)
    }
    if (ip ~ /^::ffff:[0-9.]+$/) {
      sub(/^::ffff:/, "", ip)
    }

    if (ip ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) {
      count = split(ip, octets, ".")
      if (count != 4 || octets[1] > 255 || octets[2] > 255 || \
          octets[3] > 255 || octets[4] > 255) {
        return "unknown"
      }
      if (octets[1] == 10 || octets[1] == 127 || \
          (octets[1] == 169 && octets[2] == 254) || \
          (octets[1] == 172 && octets[2] >= 16 && octets[2] <= 31) || \
          (octets[1] == 192 && octets[2] == 168)) {
        return "LAN"
      }
      return "WAN"
    }

    if (ip == "::1" || ip ~ /^f[cd][0-9a-f]*:/ || \
        ip ~ /^fe[89ab][0-9a-f]*:/) {
      return "LAN"
    }
    if (ip ~ /^[0-9a-f:]+$/ && ip ~ /:/) {
      return "WAN"
    }
    return "unknown"
  }

  BEGIN {
    OFS = sprintf("%c", 31)
    jellyfin_up = -1
    playing_collector_up = -1
    users_collector_up = -1
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

  /^jellyfin_scrape_collector_success\{collector="users"\}[[:space:]]+/ {
    users_collector_up = sample_value($0)
    next
  }

  /^jellyfin_user_active\{/ {
    key = user_key($0)
    user_scope[key] = ip_scope(label_value($0, "ip_address"))
    user_client[key] = label_value($0, "client")
    next
  }

  /^jellyfin_now_playing_state\{/ {
    media_type = label_value($0, "type")
    if (media_type !~ /^(Audio|AudioBook|Episode|Movie|MusicVideo|Trailer|Video)$/) {
      next
    }

    value = sample_value($0)
    if (!is_number(value)) {
      invalid = 1
      next
    }

    key = session_key($0)
    session_state[key] = value
    session_user_id[key] = label_value($0, "user_id")
    session_username[key] = label_value($0, "username")
    session_device[key] = label_value($0, "device")
    session_type[key] = media_type
    session_title[key] = label_value($0, "title")
    session_series[key] = label_value($0, "series_title")
    session_season[key] = label_value($0, "series_season")
    session_episode[key] = label_value($0, "series_episode")
    session_method[key] = label_value($0, "method")
    session_sort[key] = tolower(session_username[key] SUBSEP \
      session_device[key] SUBSEP session_title[key])
    next
  }

  /^jellyfin_now_playing_progress\{/ {
    value = sample_value($0)
    if (!is_number(value)) {
      invalid = 1
    } else {
      session_progress[session_key($0)] = value
    }
    next
  }

  /^jellyfin_now_playing_remaining\{/ {
    value = sample_value($0)
    if (!is_number(value)) {
      invalid = 1
    } else {
      session_remaining[session_key($0)] = value
    }
    next
  }

  END {
    if (invalid || jellyfin_up != 1 || playing_collector_up != 1 || \
        users_collector_up != 1) {
      exit 1
    }

    count = asorti(session_sort, sorted_sessions, "@val_str_asc")
    for (position = 1; position <= count; position++) {
      key = sorted_sessions[position]
      user = session_user_id[key] SUBSEP session_username[key] SUBSEP \
        session_device[key]
      scope = user_scope[user]
      if (scope == "") {
        scope = "unknown"
      }
      progress = key in session_progress ? sprintf("%.0f", session_progress[key]) : ""
      remaining = key in session_remaining ? sprintf("%.0f", session_remaining[key]) : ""
      state = session_state[key] > 0.5 ? "playing" : "paused"
      print state, \
        scope, session_username[key], session_device[key], user_client[user], \
        session_type[key], session_title[key], session_series[key], \
        session_season[key], session_episode[key], session_method[key], \
        progress, remaining
    }
  }
' <<<"$metrics")"; then
  show_error
  exit 0
fi

if [[ -z "$sessions" ]]; then
  hide_popup_rows
  sketchybar --set "$NAME" drawing=off popup.drawing=off
  exit 0
fi

count="$(awk 'NF { count++ } END { print count + 0 }' <<<"$sessions")"
active_count="$(awk -F '\037' '$1 == "playing" { count++ } END { print count + 0 }' <<<"$sessions")"
index=0
while IFS=$'\037' read -r state scope username device client media_type title \
  series season episode method progress remaining; do
  if ((index >= MAX_POPUP_SESSIONS)); then
    break
  fi

  playback_device="${device:-$client}"
  media="$title"
  if [[ "$media_type" == "Episode" ]]; then
    code="$(episode_code "$season" "$episode")"
    media="${series:-$title}"
    if [[ -n "$code" ]]; then
      media="$media $code"
    fi
    if [[ -n "$series" && -n "$title" && "$title" != "$series" ]]; then
      media="$media — $title"
    fi
  elif [[ -z "$media" ]]; then
    media="$media_type"
  fi

  if [[ "$state" == "paused" ]]; then
    if [[ -n "$progress" ]]; then
      timing="paused at ${progress}%"
    elif [[ -n "$remaining" ]]; then
      timing="paused · $(format_remaining "$remaining")"
    else
      timing="paused"
    fi
  elif [[ -n "$remaining" ]]; then
    timing="$(format_remaining "$remaining")"
  elif [[ -n "$progress" ]]; then
    timing="${progress}%"
  else
    timing="playing"
  fi

  case "$method" in
    DirectPlay | directplay) method_label="direct" ;;
    DirectStream | directstream) method_label="direct stream" ;;
    Transcode | transcode) method_label="transcode" ;;
    *) method_label="$method" ;;
  esac

  label="$scope · ${username:-Unknown} · ${playback_device:-Unknown device} · $media — $timing"
  if [[ -n "$method_label" ]]; then
    label="$label · $method_label"
  fi
  sketchybar --set "$NAME.session.$index" drawing=on label="$label"
  index=$((index + 1))
done <<<"$sessions"

while ((index < MAX_POPUP_SESSIONS)); do
  sketchybar --set "$NAME.session.$index" drawing=off
  index=$((index + 1))
done

color="$PURPLE"
if ((active_count == 0)); then
  color="$YELLOW"
fi

parent_args=(
  --set "$NAME"
  drawing=on
  icon="󰼁"
  icon.color="$color"
  label="$count"
  label.color="$color"
)
if [[ "${SENDER:-}" == "mouse.clicked" ]]; then
  parent_args+=(popup.drawing=toggle)
fi
sketchybar "${parent_args[@]}"
