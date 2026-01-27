#!/usr/bin/env bash
set -euo pipefail

calc_min_disk_kb_from_gib() {
  local gib="$1"
  printf '%s' "$((gib * 1024 * 1024))"
}

resolve_base_host() {
  local host="$1"
  case "$host" in
    pi5)
      # TODO: add DNS alias so "pi5" resolves, then remove this mapping.
      printf '%s' "dhcp"
      ;;
    *)
      printf '%s' "$host"
      ;;
  esac
}

is_work_host() {
  local host="$1"
  local work_map="$2"
  local is_work
  is_work="$(jq -r --arg h "$host" '(.nixos[$h] // .darwin[$h] // "null")' <<<"$work_map")"
  if [[ -z "$is_work" || "$is_work" == "null" ]]; then
    printf '%s' "false"
    return 0
  fi
  printf '%s' "$is_work"
}

filter_hosts_by_mode() {
  local mode="$1"
  local work_map="$2"
  shift 2

  local host is_work
  for host in "$@"; do
    is_work="$(is_work_host "$host" "$work_map")"
    if [[ "$mode" == "both" ]]; then
      printf '%s\n' "$host"
    elif [[ "$mode" == "work" && "$is_work" == "true" ]]; then
      printf '%s\n' "$host"
    elif [[ "$mode" == "personal" && "$is_work" == "false" ]]; then
      printf '%s\n' "$host"
    fi
  done
}

hosts_from_work_map() {
  local work_map="$1"
  jq -r '
    [
      (.nixos | keys[]),
      (.darwin | keys[])
    ]
    | unique
    | sort
    | .[]
  ' <<<"$work_map"
}

prioritize_hosts() {
  local host
  local -a prioritized=()
  local -a deferred=()
  local -a normal=()

  for host in "$@"; do
    if [[ "$host" == "pi5" ]]; then
      prioritized+=("$host")
    elif [[ "$host" =~ ^prx[0-9]+-lab$ || "$host" == "nvws" ]]; then
      prioritized+=("$host")
    elif [[ "$host" == *cachevm* ]]; then
      deferred+=("$host")
    else
      normal+=("$host")
    fi
  done

  printf '%s\n' "${prioritized[@]}" "${normal[@]}" "${deferred[@]}"
}
