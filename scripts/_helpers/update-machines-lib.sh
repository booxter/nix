#!/usr/bin/env bash
set -euo pipefail

calc_min_disk_kb_from_gib() {
  local gib="$1"
  printf '%s' "$((gib * 1024 * 1024))"
}

is_ipv4_address() {
  local host="$1"
  [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

is_bare_hostname() {
  local host="$1"
  [[ "$host" != *.* ]] && ! is_ipv4_address "$host"
}

lan_dns_lookup_candidates() {
  local host="$1"
  local domain="${2:-}"

  printf '%s\n' "$host"
  if [[ -n "$domain" ]] && is_bare_hostname "$host"; then
    printf '%s.%s\n' "$host" "$domain"
  fi
}

resolve_base_host() {
  local host="$1"
  if [[ -z "${HOST_BASE_MAP_JSON:-}" ]]; then
    printf '%s' "$host"
    return 0
  fi

  jq -r --arg h "$host" '.[$h] // $h' <<<"$HOST_BASE_MAP_JSON"
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
    if [[ "$host" =~ ^prx[0-9]+-lab$ || "$host" == "nvws" ]]; then
      prioritized+=("$host")
    elif [[ "$host" == *cachevm* ]]; then
      deferred+=("$host")
    else
      normal+=("$host")
    fi
  done

  printf '%s\n' "${prioritized[@]}" "${normal[@]}" "${deferred[@]}"
}

format_host_list() {
  local host

  if [[ $# -eq 0 ]]; then
    return 0
  fi

  printf '%s' "$1"
  shift

  for host in "$@"; do
    printf ', %s' "$host"
  done
}

run_nh_from_repo() {
  nix shell --inputs-from . nixpkgs#nh nixpkgs#nix-output-monitor -c nh "$@"
}

run_nixos_rebuild_from_repo() {
  local rebuild_action="$1"
  local host_name="$2"

  if [[ "$rebuild_action" == "dry-activate" ]]; then
    sudo nixos-rebuild "$rebuild_action" --flake ".#${host_name}" -L --show-trace
    return 0
  fi

  if [[ "$rebuild_action" != "switch" && "$rebuild_action" != "boot" ]]; then
    echo "Unsupported NixOS deploy action: ${rebuild_action}." >&2
    return 1
  fi

  run_nh_from_repo os "$rebuild_action" \
    --hostname "$host_name" \
    --print-build-logs \
    --show-trace \
    ".#"
}

run_darwin_switch_from_repo() {
  local host_name="$1"

  run_nh_from_repo darwin switch \
    --hostname "$host_name" \
    --print-build-logs \
    --show-trace \
    ".#"
}
