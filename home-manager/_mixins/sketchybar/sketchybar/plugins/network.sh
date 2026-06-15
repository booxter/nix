#!/usr/bin/env bash

scope="${NETWORK_SCOPE:-wan}"
metrics_file="${LAN_WAN_METRICS_FILE:-/var/lib/prometheus-node-exporter-textfile/lan-wan.prom}"
metrics_max_age_seconds="${LAN_WAN_METRICS_MAX_AGE_SECONDS:-90}"

if ! [[ "$metrics_max_age_seconds" =~ ^[0-9]+$ ]]; then
  metrics_max_age_seconds=90
fi

stat_mtime() {
  local mtime

  mtime="$(/usr/bin/stat -f %m "$1" 2>/dev/null)"
  if [[ "$mtime" =~ ^[0-9]+$ ]]; then
    echo "$mtime"
    return
  fi

  stat -c %Y "$1" 2>/dev/null
}

metrics_fresh() {
  [[ -r "$metrics_file" ]] || return 1

  local mtime now age
  mtime="$(stat_mtime "$metrics_file")" || return 1
  [[ "$mtime" =~ ^[0-9]+$ ]] || return 1

  now="$(date +%s)"
  age=$(( now - mtime ))
  (( age >= 0 && age <= metrics_max_age_seconds ))
}

read_rate_metric() {
  local direction="$1"

  metrics_fresh || return 1
  awk -v direction="$direction" -v scope="$scope" '
    $1 ~ /^host_observability_network_bytes_per_second\{/ &&
    $1 ~ "direction=\"" direction "\"" &&
    $1 ~ "scope=\"" scope "\"" {
      print $2
      found = 1
      exit
    }
    END { if (!found) exit 1 }
  ' "$metrics_file"
}

read_metric_rates() {
  DOWN="$(read_rate_metric receive)" || return 1
  UP="$(read_rate_metric transmit)" || return 1
}

human_readable() {
  local bytes="${1}"
  local precision="${2}"

  awk -v bytes="$bytes" -v precision="$precision" '
    BEGIN {
      split("B K M G T E Z", units, " ")
      if (bytes < 0) {
        bytes = 0
      }
      unit = 1
      while (bytes >= 1024 && unit < 7) {
        bytes /= 1024
        unit++
      }
      if (unit == 1) {
        printf "%.0f%s\n", bytes, units[unit]
      } else {
        printf "%.*f%s\n", precision, bytes, units[unit]
      }
    }
  '
}

DOWN=0
UP=0
read_metric_rates || true

DOWN_FORMAT=$(human_readable "$DOWN" 1)
UP_FORMAT=$(human_readable "$UP" 1)

sketchybar -m --set network.down label="$DOWN_FORMAT" \
	       --set network.up   label="$UP_FORMAT"
