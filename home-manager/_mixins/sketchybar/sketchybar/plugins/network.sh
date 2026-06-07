#!/usr/bin/env bash

iface="${1:-en0}"
scope="${NETWORK_SCOPE:-wan}"
metrics_file="${LAN_WAN_METRICS_FILE:-/var/lib/prometheus-node-exporter-textfile/lan-wan.prom}"
metrics_max_age_seconds="${LAN_WAN_METRICS_MAX_AGE_SECONDS:-90}"
Ibytes_Column=7
Obytes_Column=8

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

read_bpf_rates() {
  DOWN="$(read_rate_metric receive)" || return 1
  UP="$(read_rate_metric transmit)" || return 1
}

get_bytes() {
  netstat -bI "$iface" 2>/dev/null | awk -v i="$iface" -v col="$1" '
    NR>1 && $1==i && $3 ~ /<Link/ { print $ col; exit }
  '
}

measure_ibw() {
  b1="$(get_bytes "$Ibytes_Column")"
  sleep 1
  b2="$(get_bytes "$Ibytes_Column")"

  get_delta "$b1" "$b2"
}

measure_obw() {
  b1="$(get_bytes "$Obytes_Column")"
  sleep 1
  b2="$(get_bytes "$Obytes_Column")"

  get_delta "$b1" "$b2"
}

get_delta() {
  local b1="$1"
  local b2="$2"

  # Basic validation
  if [[ -z "$b1" || -z "$b2" ]]; then
    echo "0"
    return
  fi

  # Handle normal case; if a rare counter wrap makes this negative, clamp to 0.
  local delta=$(( b2 - b1 ))
  if (( delta < 0 )); then delta=0; fi
  echo "$delta"
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

if ! read_bpf_rates; then
  UP=$(measure_obw)
  DOWN=$(measure_ibw)
fi

DOWN_FORMAT=$(human_readable "$DOWN" 1)
UP_FORMAT=$(human_readable "$UP" 1)

sketchybar -m --set network.down label="$DOWN_FORMAT" \
	       --set network.up   label="$UP_FORMAT"
