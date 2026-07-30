#!/usr/bin/env bash

if ! disk_stats="$(df -Pk "$HOME" 2>/dev/null | awk 'NR == 2 { print $2, $4 }')"; then
  exit 0
fi

read -r total_kb available_kb <<<"$disk_stats"
if [[ ! "$total_kb" =~ ^[0-9]+$ || ! "$available_kb" =~ ^[0-9]+$ || "$total_kb" -eq 0 ]]; then
  exit 0
fi

remaining_percentage=$((available_kb * 100 / total_kb))
sketchybar --set "$NAME" label="${remaining_percentage}%"
