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

resolve_runtime_host() {
  local host="$1"
  if [[ -z "${HOST_RUNTIME_MAP_JSON:-}" ]]; then
    printf '%s' "$host"
    return 0
  fi

  jq -r --arg h "$host" '.[$h] // $h' <<<"$HOST_RUNTIME_MAP_JSON"
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
  local host="$1"
  local display

  if [[ -z "${HOST_DISPLAY_MAP_JSON:-}" ]]; then
    printf '%s' "$host"
    return 0
  fi

  display="$(jq -r --arg h "$host" '.[$h] // $h' <<<"$HOST_DISPLAY_MAP_JSON")"
  printf '%s' "$display"
}

format_display_host_list() {
  local host
  local -a display_hosts=()

  for host in "$@"; do
    display_hosts+=("$(display_host_name "$host")")
  done

  format_host_list "${display_hosts[@]}"
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
    elif [[ "$host" == "cache" || "$host" == *cachevm* ]]; then
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
  local bash_bin=""
  local nix_bin=""
  local out_link=""
  local status=0
  local system_config=""
  local tmpdir=""

  bash_bin="$(command -v bash)"
  nix_bin="$(command -v nix)"
  tmpdir="$(mktemp -d)"
  out_link="${tmpdir}/system"

  if run_nh_from_repo darwin build \
    --hostname "$host_name" \
    --out-link "$out_link" \
    --print-build-logs \
    --show-trace \
    --diff auto \
    ".#"; then
    :
  else
    status=$?
    rm -rf "$tmpdir"
    return "$status"
  fi

  if system_config="$(readlink "$out_link")"; then
    :
  else
    echo "Failed to resolve Darwin system configuration output link for ${host_name}: ${out_link}" >&2
    rm -rf "$tmpdir"
    return 1
  fi

  if [[ -z "$system_config" ]]; then
    echo "Failed to build Darwin system configuration for ${host_name}: nix returned no output path." >&2
    rm -rf "$tmpdir"
    return 1
  fi

  if sudo "$bash_bin" -e -u -o pipefail -c '
    nix_bin="$1"
    system_config="$2"

    "$nix_bin" build --no-link --profile /nix/var/nix/profiles/system "$system_config"
    "$system_config/sw/bin/darwin-rebuild" activate
  ' bash "$nix_bin" "$system_config"; then
    :
  else
    status=$?
  fi

  rm -rf "$tmpdir"
  return "$status"
}
