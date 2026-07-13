#!/usr/bin/env bash
set -euo pipefail

calc_min_disk_kb_from_gib() {
  local gib="$1"
  printf '%s' "$((gib * 1024 * 1024))"
}

prepare_local_deploy_source() {
  local checkout_start="$1"
  local checkout_root

  if ! checkout_root="$(git -C "$checkout_start" rev-parse --show-toplevel 2>/dev/null)"; then
    echo "--local must be run from inside a Git checkout." >&2
    return 1
  fi

  LOCAL_SOURCE_COMMIT="$(git -C "$checkout_root" rev-parse --verify HEAD)"
  LOCAL_SOURCE_ROOT="$(mktemp -d)"
  LOCAL_SOURCE_ROOT="$(cd "$LOCAL_SOURCE_ROOT" && pwd -P)"
  LOCAL_SOURCE_ARCHIVE="${LOCAL_SOURCE_ROOT}/repo.tar"
  LOCAL_SOURCE_CHECKOUT="${LOCAL_SOURCE_ROOT}/repo"
  mkdir -p "$LOCAL_SOURCE_CHECKOUT"
  git -C "$checkout_root" archive --format=tar --output="$LOCAL_SOURCE_ARCHIVE" HEAD
  tar -xf "$LOCAL_SOURCE_ARCHIVE" -C "$LOCAL_SOURCE_CHECKOUT"
  echo "Using committed checkout state ${LOCAL_SOURCE_COMMIT} from ${checkout_root}."
}

looks_like_ipv4_address() {
  local host="$1"
  [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

is_bare_hostname() {
  local host="$1"
  [[ "$host" != *.* ]] && ! looks_like_ipv4_address "$host"
}

lan_dns_lookup_candidates() {
  local host="$1"
  local domain="${2:-}"

  printf '%s\n' "$host"
  if [[ -n "$domain" ]] && is_bare_hostname "$host"; then
    printf '%s.%s\n' "$host" "$domain"
  fi
}

lookup_host_map_or_identity() {
  local host="$1"
  local host_map_json="$2"

  if [[ -z "$host_map_json" ]]; then
    printf '%s' "$host"
    return 0
  fi

  jq -r --arg host "$host" '.[$host] // $host' <<<"$host_map_json"
}

resolve_base_host() {
  lookup_host_map_or_identity "$1" "${HOST_BASE_MAP_JSON:-}"
}

resolve_runtime_host() {
  lookup_host_map_or_identity "$1" "${HOST_RUNTIME_MAP_JSON:-}"
}

resolve_host_alias() {
  local host="$1"
  local resolved

  if [[ -z "${HOST_ALIAS_MAP_JSON:-}" ]]; then
    printf '%s' "$host"
    return 0
  fi

  resolved="$(jq -r --arg h "$host" 'if has($h) then .[$h] else empty end' <<<"$HOST_ALIAS_MAP_JSON")"
  if [[ -z "$resolved" ]]; then
    echo "Unknown host: ${host}" >&2
    return 1
  fi

  printf '%s' "$resolved"
}

canonicalize_hosts() {
  local host

  for host in "$@"; do
    resolve_host_alias "$host"
    printf '\n'
  done
}

display_host_name() {
  lookup_host_map_or_identity "$1" "${HOST_DISPLAY_MAP_JSON:-}"
}

format_display_host_list() {
  local host
  local -a display_hosts=()

  for host in "$@"; do
    display_hosts+=("$(display_host_name "$host")")
  done

  format_host_list "${display_hosts[@]}"
}

host_metadata_from_host_map() {
  local host="$1"
  local host_map="$2"

  jq -r --arg host "$host" '
    if (.nixos | has($host)) then
      ["nixos", .nixos[$host].isWork] | @tsv
    elif (.darwin | has($host)) then
      ["darwin", .darwin[$host].isWork] | @tsv
    else empty
    end
  ' <<<"$host_map"
}

is_work_host() {
  local metadata
  local is_work

  metadata="$(host_metadata_from_host_map "$1" "$2")"
  if [[ -z "$metadata" ]]; then
    printf '%s' "false"
    return 0
  fi

  IFS=$'\t' read -r _ is_work <<<"$metadata"
  printf '%s' "$is_work"
}

filter_hosts_by_mode() {
  local mode="$1"
  local host_map="$2"
  shift 2

  if [[ "$mode" == "both" ]]; then
    printf '%s\n' "$@"
    return 0
  fi

  local host is_work
  for host in "$@"; do
    is_work="$(is_work_host "$host" "$host_map")"
    if [[ "$mode" == "work" && "$is_work" == "true" ]]; then
      printf '%s\n' "$host"
    elif [[ "$mode" == "personal" && "$is_work" == "false" ]]; then
      printf '%s\n' "$host"
    fi
  done
}

hosts_from_host_map() {
  local host_map="$1"
  jq -r '
    [
      (.nixos | keys[]),
      (.darwin | keys[])
    ]
    | unique
    | sort
    | .[]
  ' <<<"$host_map"
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
