#!/usr/bin/env sh

iface="${1:-en0}"
Ibytes_Column=7
Obytes_Column=8

get_bytes() {
  netstat -bI "$iface" 2>/dev/null | awk -v i="$iface" -v col="$1" '
    NR>1 && $1==i && $3 ~ /<Link/ { print $ col; exit }
  '
}

measure_ibw() {
  b1="$(get_bytes $Ibytes_Column)"
  sleep 1
  b2="$(get_bytes $Ibytes_Column)"

  get_delta "$b1" "$b2"
}

measure_obw() {
  b1="$(get_bytes $Obytes_Column)"
  sleep 1
  b2="$(get_bytes $Obytes_Column)"

  get_delta "$b1" "$b2"
}

get_delta() {
  local b1=$1
  local b2=$2

  # Basic validation
  if [[ -z "$b1" || -z "$b2" ]]; then
    echo "-1"
  fi

  # Handle normal case; if a rare counter wrap makes this negative, clamp to 0.
  delta=$(( b2 - b1 ))
  if (( delta < 0 )); then delta=0; fi
  echo $delta
}

UP=$(measure_obw)
DOWN=$(measure_ibw)

function human_readable() {
    local abbrevs=(
        $((1 << 60)):Z
        $((1 << 50)):E
        $((1 << 40)):T
        $((1 << 30)):G
        $((1 << 20)):M
        $((1 << 10)):K
        $((1)):B
    )

    local bytes="${1}"
    local precision="${2}"

    for item in "${abbrevs[@]}"; do
        local factor="${item%:*}"
        local abbrev="${item#*:}"
        if [[ "${bytes}" -ge "${factor}" ]]; then
            local size="$(bc -l <<< "${bytes} / ${factor}")"
            printf "%.*f%s\n" "${precision}" "${size}" "${abbrev}"
            break
        fi
    done
}

DOWN_FORMAT=$(human_readable $DOWN 1)
UP_FORMAT=$(human_readable $UP 1)

sketchybar -m --set network.down label="$DOWN_FORMAT" \
	       --set network.up   label="$UP_FORMAT"
