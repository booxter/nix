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

host_kind_from_work_map() {
  local host="$1"
  local work_map="$2"

  jq -r --arg host "$host" '
    if (.nixos | has($host)) then "nixos"
    elif (.darwin | has($host)) then "darwin"
    else empty
    end
  ' <<<"$work_map"
}

is_work_host() {
  local host="$1"
  local work_map="$2"
  local kind

  kind="$(host_kind_from_work_map "$host" "$work_map")"
  if [[ -z "$kind" ]]; then
    printf '%s' "false"
    return 0
  fi

  jq -r --arg kind "$kind" --arg host "$host" '.[$kind][$host]' <<<"$work_map"
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

prebuild_deploy_targets() {
  local branch="$1"
  local repo_url="$2"
  local work_map="$3"
  shift 3

  local flake_ref host kind
  local -a installables=()

  flake_ref="git+https://github.com/${repo_url#github.com:}.git?ref=${branch}"
  for host in "$@"; do
    kind="$(host_kind_from_work_map "$host" "$work_map")"
    case "$kind" in
      nixos)
        installables+=("${flake_ref}#nixosConfigurations.${host}.config.system.build.toplevel")
        ;;
      darwin)
        installables+=("${flake_ref}#darwinConfigurations.${host}.system")
        ;;
      *)
        echo "Cannot prebuild unknown host: ${host}" >&2
        return 1
        ;;
    esac
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
  local askpass_script=""
  local has_tty=false
  local pam_service_file="${SUDO_SSH_PASSWORD_PAM_SERVICE_FILE:-/etc/pam.d/sudo_ssh_password}"
  local sudo_args=()
  local status=0

  if [[ -t 0 && -t 1 ]] || [[ "${UPDATE_MACHINES_TEST_ASSUME_TTY:-false}" == "true" ]]; then
    has_tty=true
  fi

  if [[ -n "${SSH_CONNECTION:-}" && "$has_tty" == "true" && -f "$pam_service_file" ]]; then
    askpass_script="$(mktemp)"
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
    sudo_args=(-A)
    if SUDO_ASKPASS="$askpass_script" sudo "${sudo_args[@]}" "$@"; then
      status=0
    else
      status=$?
    fi
    rm -f "$askpass_script"
    return "$status"
  fi

  sudo "$@"
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

  rm -rf "$tmpdir"
  return "$status"
}
