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
      ["nixos", .nixos[$host].isWork, .nixos[$host].deployPriority] | @tsv
    elif (.darwin | has($host)) then
      ["darwin", .darwin[$host].isWork, .darwin[$host].deployPriority] | @tsv
    else empty
    end
  ' <<<"$host_map"
}

host_kind_from_host_map() {
  local metadata

  metadata="$(host_metadata_from_host_map "$1" "$2")"
  printf '%s' "${metadata%%$'\t'*}"
}

is_work_host() {
  local metadata
  local is_work

  metadata="$(host_metadata_from_host_map "$1" "$2")"
  if [[ -z "$metadata" ]]; then
    printf '%s' "false"
    return 0
  fi

  IFS=$'\t' read -r _ is_work _ <<<"$metadata"
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

prioritize_hosts() {
  local host_map="$1"
  shift

  local host
  local -a prioritized=()
  local -a deferred=()
  local -a normal=()

  for host in "$@"; do
    case "$(deploy_priority_from_host_map "$host" "$host_map")" in
      early) prioritized+=("$host") ;;
      late) deferred+=("$host") ;;
      *) normal+=("$host") ;;
    esac
  done

  printf '%s\n' "${prioritized[@]}" "${normal[@]}" "${deferred[@]}"
}

deploy_priority_from_host_map() {
  local metadata
  local deploy_priority

  metadata="$(host_metadata_from_host_map "$1" "$2")"
  if [[ -z "$metadata" ]]; then
    printf '%s' "normal"
    return 0
  fi

  IFS=$'\t' read -r _ _ deploy_priority <<<"$metadata"
  printf '%s' "$deploy_priority"
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

deploy_installable_for_host() {
  local flake_ref="$1"
  local host="$2"
  local host_map="$3"

  case "$(host_kind_from_host_map "$host" "$host_map")" in
    nixos)
      printf '%s#nixosConfigurations.%s.config.system.build.toplevel' "$flake_ref" "$host"
      ;;
    darwin)
      printf '%s#darwinConfigurations.%s.system' "$flake_ref" "$host"
      ;;
    *)
      echo "Cannot construct deploy installable for unknown host: ${host}" >&2
      return 1
      ;;
  esac
}

prebuild_deploy_targets() {
  local branch="$1"
  local repo_url="$2"
  local host_map="$3"
  shift 3

  local flake_ref host
  local -a installables=()

  flake_ref="git+https://github.com/${repo_url#github.com:}.git?ref=${branch}"
  for host in "$@"; do
    installables+=("$(deploy_installable_for_host "$flake_ref" "$host" "$host_map")")
  done

  echo "Prebuilding ${#installables[@]} deployment target(s) from branch ${branch}..."
  nix build -L --show-trace --no-link "${installables[@]}"
}

prebuild_local_deploy_targets() {
  local repo_dir="$1"
  local commit="$2"
  local host_map="$3"
  shift 3

  local flake_ref host
  local -a installables=()

  flake_ref="path:${repo_dir}"
  for host in "$@"; do
    installables+=("$(deploy_installable_for_host "$flake_ref" "$host" "$host_map")")
  done

  echo "Prebuilding ${#installables[@]} deployment target(s) from local commit ${commit}..."
  nix build -L --show-trace --no-link "${installables[@]}"
}
