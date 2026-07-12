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

host_metadata_from_work_map() {
  local host="$1"
  local work_map="$2"

  jq -r --arg host "$host" '
    if (.nixos | has($host)) then ["nixos", .nixos[$host]] | @tsv
    elif (.darwin | has($host)) then ["darwin", .darwin[$host]] | @tsv
    else empty
    end
  ' <<<"$work_map"
}

host_kind_from_work_map() {
  local metadata

  metadata="$(host_metadata_from_work_map "$1" "$2")"
  printf '%s' "${metadata%%$'\t'*}"
}

is_work_host() {
  local metadata

  metadata="$(host_metadata_from_work_map "$1" "$2")"
  if [[ -z "$metadata" ]]; then
    printf '%s' "false"
    return 0
  fi

  printf '%s' "${metadata#*$'\t'}"
}

filter_hosts_by_mode() {
  local mode="$1"
  local work_map="$2"
  shift 2

  if [[ "$mode" == "both" ]]; then
    printf '%s\n' "$@"
    return 0
  fi

  local host is_work
  for host in "$@"; do
    is_work="$(is_work_host "$host" "$work_map")"
    if [[ "$mode" == "work" && "$is_work" == "true" ]]; then
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

deploy_installable_for_host() {
  local flake_ref="$1"
  local host="$2"
  local work_map="$3"

  case "$(host_kind_from_work_map "$host" "$work_map")" in
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
  local work_map="$3"
  shift 3

  local flake_ref host
  local -a installables=()

  flake_ref="git+https://github.com/${repo_url#github.com:}.git?ref=${branch}"
  for host in "$@"; do
    installables+=("$(deploy_installable_for_host "$flake_ref" "$host" "$work_map")")
  done

  echo "Prebuilding ${#installables[@]} deployment target(s) from branch ${branch}..."
  nix build -L --show-trace --no-link "${installables[@]}"
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

run_sudo_for_remote_darwin() {
  local has_tty=false
  local pam_service_file="${SUDO_SSH_PASSWORD_PAM_SERVICE_FILE:-/etc/pam.d/sudo_ssh_password}"

  if [[ -t 0 && -t 1 ]] || [[ "${UPDATE_MACHINES_TEST_ASSUME_TTY:-false}" == "true" ]]; then
    has_tty=true
  fi

  if [[ -n "${SSH_CONNECTION:-}" && "$has_tty" == "true" && -f "$pam_service_file" ]]; then
    (
      local askpass_script
      askpass_script="$(mktemp)"
      trap 'rm -f "$askpass_script"' EXIT
      cat > "$askpass_script" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

prompt="${1:-Password:}"
printf '%s' "$prompt" > /dev/tty
saved_tty="$(stty -g < /dev/tty)"
trap 'stty "$saved_tty" < /dev/tty 2>/dev/null' EXIT HUP INT TERM
stty -echo < /dev/tty
IFS= read -r password < /dev/tty
printf '\n' > /dev/tty
printf '%s\n' "$password"
EOF
      chmod 700 "$askpass_script"
      SUDO_ASKPASS="$askpass_script" sudo -A "$@"
    )
    return $?
  fi

  sudo "$@"
}

run_darwin_switch_from_repo() (
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
  trap 'rm -rf "$tmpdir"' EXIT
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
    return "$status"
  fi

  if system_config="$(readlink "$out_link")"; then
    :
  else
    echo "Failed to resolve Darwin system configuration output link for ${host_name}: ${out_link}" >&2
    return 1
  fi

  if [[ -z "$system_config" ]]; then
    echo "Failed to build Darwin system configuration for ${host_name}: nix returned no output path." >&2
    return 1
  fi

  # shellcheck disable=SC2016
  if run_sudo_for_remote_darwin "$bash_bin" -e -u -o pipefail -c '
    nix_bin="$1"
    system_config="$2"

    "$nix_bin" build --no-link --profile /nix/var/nix/profiles/system "$system_config"
    "$system_config/sw/bin/darwin-rebuild" activate
  ' bash "$nix_bin" "$system_config"; then
    :
  else
    status=$?
  fi

  return "$status"
)
