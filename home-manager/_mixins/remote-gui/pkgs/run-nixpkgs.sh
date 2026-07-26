#!/usr/bin/env bash
# shellcheck shell=bash

set -euo pipefail

program_name="${RUN_NIXPKGS_PROGRAM_NAME:?RUN_NIXPKGS_PROGRAM_NAME is required}"
transport="${RUN_NIXPKGS_TRANSPORT:?RUN_NIXPKGS_TRANSPORT is required}"

usage() {
  local transport_description

  case "${transport}" in
    x11)
      transport_description="SSH X11 forwarding"
      ;;
    waypipe)
      transport_description="Cocoa-Way and Waypipe"
      ;;
    *)
      transport_description="the configured remote GUI transport"
      ;;
  esac

  cat <<EOF
Usage: ${program_name} [options] <pr-or-flake-ref> <package-attr> [-- program-args...]

Build a Linux package on a remote host and run it through ${transport_description}.

PR shortcuts are resolved against NixOS/nixpkgs:
  ${program_name} 538891 podman-desktop
  ${program_name} https://github.com/NixOS/nixpkgs/pull/538891 podman-desktop

Flake refs are accepted as-is:
  ${program_name} github:NixOS/nixpkgs/nixos-unstable podman-desktop

Options:
  --host HOST       SSH host to build and run on (default: frame)
  --cmd NAME        Run \$out/bin/NAME instead of auto-detecting mainProgram
  --allow-unfree    Set NIXPKGS_ALLOW_UNFREE=1 for the remote nix commands
  --ssh-option OPT  Pass one -o option to ssh; repeat as needed
  --dry-run         Print the resolved installable and SSH target, then exit
  --help            Show this help
EOF

  if [[ "${transport}" == x11 ]]; then
    cat <<EOF
  --trusted         Use trusted X11 forwarding (-Y) instead of -X
EOF
  fi
}

normalize_flake_ref() {
  local source="$1"

  if [[ "${source}" =~ ^#?([0-9]+)$ ]]; then
    printf 'github:NixOS/nixpkgs?ref=pull/%s/head\n' "${BASH_REMATCH[1]}"
    return 0
  fi

  if [[ "${source}" =~ ^https://github\.com/([^/]+)/([^/]+)/pull/([0-9]+)([/#?].*)?$ ]]; then
    printf 'github:%s/%s?ref=pull/%s/head\n' \
      "${BASH_REMATCH[1]}" \
      "${BASH_REMATCH[2]}" \
      "${BASH_REMATCH[3]}"
    return 0
  fi

  if [[ "${source}" =~ ^github\.com/([^/]+)/([^/]+)/pull/([0-9]+)([/#?].*)?$ ]]; then
    printf 'github:%s/%s?ref=pull/%s/head\n' \
      "${BASH_REMATCH[1]}" \
      "${BASH_REMATCH[2]}" \
      "${BASH_REMATCH[3]}"
    return 0
  fi

  printf '%s\n' "${source}"
}

quote_remote_arg() {
  local quoted="${1//\'/\'\\\'\'}"

  printf "'%s'" "${quoted}"
}

find_wayland_socket() {
  local directory="$1"
  local socket_probe="${WRUN_NIXPKGS_SOCKET_PROBE:-socat}"
  local socket

  [[ -d "${directory}" ]] || return 1
  for socket in "${directory}"/wayland-*; do
    # Cocoa-Way may leave the socket inode behind after exiting, so verify that
    # a compositor is actually accepting connections.
    if [[ -S "${socket}" ]] \
      && "${socket_probe}" -T 1 -u OPEN:/dev/null "UNIX-CONNECT:${socket}" \
        >/dev/null 2>&1; then
      printf '%s\n' "${socket}"
      return 0
    fi
  done
  return 1
}

discover_wayland_display() {
  local directory
  local socket=""
  local -a candidates=()

  if [[ -n "${XDG_RUNTIME_DIR:-}" && -n "${WAYLAND_DISPLAY:-}" ]] \
    && [[ -S "${XDG_RUNTIME_DIR%/}/${WAYLAND_DISPLAY}" ]]; then
    return 0
  fi

  [[ -n "${COCOA_WAY_RUNTIME_DIR:-}" ]] && candidates+=("${COCOA_WAY_RUNTIME_DIR}")
  [[ -n "${XDG_RUNTIME_DIR:-}" ]] && candidates+=("${XDG_RUNTIME_DIR}")
  [[ -n "${TMPDIR:-}" ]] && candidates+=("${TMPDIR%/}/cocoa-way")
  candidates+=("/tmp/cocoa-way")

  for directory in "${candidates[@]}"; do
    socket="$(find_wayland_socket "${directory}" || true)"
    [[ -n "${socket}" ]] && break
  done

  [[ -n "${socket}" ]] || return 1

  export XDG_RUNTIME_DIR="${socket%/*}"
  export WAYLAND_DISPLAY="${socket##*/}"
}

start_cocoa_way() {
  local launchctl_bin="${WRUN_NIXPKGS_LAUNCHCTL:-/bin/launchctl}"
  local service="${WRUN_NIXPKGS_COCOA_WAY_SERVICE:-org.nixos.cocoa-way}"
  local target="gui/${UID}/${service}"

  echo "Starting Cocoa-Way through launchd..." >&2
  if ! "${launchctl_bin}" kickstart "${target}"; then
    echo "Unable to start Cocoa-Way through launchd service ${service}." >&2
    echo "Activate host.remoteGui.wayland, or start Cocoa-Way manually." >&2
    return 1
  fi
}

configure_wayland_display() {
  local attempt
  local attempts="${WRUN_NIXPKGS_START_ATTEMPTS:-100}"
  local delay="${WRUN_NIXPKGS_START_DELAY:-0.1}"

  if discover_wayland_display; then
    echo "Using Cocoa-Way socket: ${XDG_RUNTIME_DIR}/${WAYLAND_DISPLAY}" >&2
    return 0
  fi

  start_cocoa_way
  for ((attempt = 0; attempt < attempts; attempt++)); do
    if discover_wayland_display; then
      echo "Using Cocoa-Way socket: ${XDG_RUNTIME_DIR}/${WAYLAND_DISPLAY}" >&2
      return 0
    fi
    sleep "${delay}"
  done

  echo "Timed out waiting for the Cocoa-Way socket." >&2
  echo "Inspect it with: launchctl print gui/${UID}/org.nixos.cocoa-way" >&2
  return 1
}

run_remote() {
  local host="$1"
  local forwarding="$2"
  local remote_command="$3"
  shift 3
  local -a ssh_args=("$@")
  local -a launcher=()

  case "${transport}" in
    x11)
      launcher=(ssh "${forwarding}" "${ssh_args[@]}")
      ;;
    waypipe)
      local waypipe_bin="${WRUN_NIXPKGS_WAYPIPE:-}"
      local remote_waypipe="${WRUN_NIXPKGS_REMOTE_WAYPIPE:-waypipe}"
      local compression="${WRUN_NIXPKGS_COMPRESS:-zstd}"

      configure_wayland_display
      if [[ -z "${waypipe_bin}" ]]; then
        waypipe_bin="$(command -v waypipe || true)"
      fi
      if [[ -z "${waypipe_bin}" ]]; then
        echo "waypipe-darwin is not installed or not available in PATH." >&2
        exit 1
      fi

      launcher=(
        "${waypipe_bin}"
        --no-gpu
        "--compress=${compression}"
        --remote-bin
        "${remote_waypipe}"
        ssh
        -o
        StreamLocalBindUnlink=yes
        "${ssh_args[@]}"
      )
      ;;
    *)
      echo "Unsupported remote GUI transport: ${transport}" >&2
      exit 70
      ;;
  esac

  exec "${launcher[@]}" "${host}" "${remote_command}" <<'REMOTE'
set -euo pipefail

flake_ref="$1"
package_attr="$2"
command="$3"
allow_unfree="$4"
shift 4

installable="${flake_ref}#${package_attr}"
nix_cmd=(nix --extra-experimental-features "nix-command flakes")

if [ "${allow_unfree}" = true ]; then
  export NIXPKGS_ALLOW_UNFREE=1
  nix_cmd+=(--impure)
fi

echo "Building ${installable} on $(hostname)..." >&2
build_output="$("${nix_cmd[@]}" build --no-link --print-out-paths -L --show-trace "${installable}")"
out_path="${build_output%%$'\n'*}"

if [ -z "${out_path}" ]; then
  echo "nix build did not return an output path for ${installable}" >&2
  exit 1
fi

if [ -z "${command}" ]; then
  command="$("${nix_cmd[@]}" eval --raw "${installable}.meta.mainProgram" 2>/dev/null || true)"
fi

if [ -z "${command}" ]; then
  command="${package_attr##*.}"
fi

if [[ "${command}" == */* ]]; then
  run_path="${command}"
else
  run_path="${out_path}/bin/${command}"
fi

if [ ! -x "${run_path}" ]; then
  echo "Unable to find executable for ${installable}." >&2
  echo "Tried: ${run_path}" >&2
  if [ -d "${out_path}/bin" ]; then
    echo "Available executables in ${out_path}/bin:" >&2
    for candidate in "${out_path}"/bin/*; do
      if [ -x "${candidate}" ] && [ ! -d "${candidate}" ]; then
        printf '  %s\n' "$(basename "${candidate}")" >&2
      fi
    done
  fi
  exit 1
fi

echo "Running ${run_path}..." >&2
exec "${run_path}" "$@"
REMOTE
}

main() {
  local host="${RUN_NIXPKGS_HOST:-frame}"
  local command=""
  local allow_unfree="${RUN_NIXPKGS_ALLOW_UNFREE:-false}"
  local forwarding="-X"
  local dry_run=false
  local -a ssh_args=()

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --help)
        usage
        exit 0
        ;;
      --host)
        shift
        if [ "$#" -eq 0 ] || [ -z "$1" ]; then
          echo "--host requires a value" >&2
          exit 64
        fi
        host="$1"
        ;;
      --cmd | --command)
        shift
        if [ "$#" -eq 0 ] || [ -z "$1" ]; then
          echo "--cmd requires a value" >&2
          exit 64
        fi
        command="$1"
        ;;
      --allow-unfree)
        allow_unfree=true
        ;;
      --trusted)
        if [[ "${transport}" != x11 ]]; then
          echo "--trusted is only available for X11 forwarding" >&2
          exit 64
        fi
        forwarding="-Y"
        ;;
      --ssh-option)
        shift
        if [ "$#" -eq 0 ] || [ -z "$1" ]; then
          echo "--ssh-option requires a value" >&2
          exit 64
        fi
        ssh_args+=("-o" "$1")
        ;;
      --dry-run)
        dry_run=true
        ;;
      --)
        shift
        break
        ;;
      -*)
        echo "Unknown option: $1" >&2
        echo >&2
        usage >&2
        exit 64
        ;;
      *)
        break
        ;;
    esac
    shift
  done

  if [ "$#" -lt 2 ]; then
    usage >&2
    exit 64
  fi

  local source="$1"
  local package_attr="$2"
  shift 2

  if [ "$#" -gt 0 ] && [ "$1" = "--" ]; then
    shift
  fi

  local flake_ref
  flake_ref="$(normalize_flake_ref "${source}")"

  if [ "${dry_run}" = true ]; then
    printf 'ssh host: %s\n' "${host}"
    printf 'transport: %s\n' "${transport}"
    if [[ "${transport}" == x11 ]]; then
      printf 'x11 forwarding: %s\n' "${forwarding}"
    else
      printf 'remote waypipe: %s\n' "${WRUN_NIXPKGS_REMOTE_WAYPIPE:-waypipe}"
    fi
    printf 'installable: %s#%s\n' "${flake_ref}" "${package_attr}"
    printf 'command: %s\n' "${command:-auto}"
    printf 'allow unfree: %s\n' "${allow_unfree}"
    exit 0
  fi

  local remote_command="bash -s --"
  local remote_arg
  for remote_arg in "${flake_ref}" "${package_attr}" "${command}" "${allow_unfree}" "$@"; do
    remote_command+=" $(quote_remote_arg "${remote_arg}")"
  done

  run_remote "${host}" "${forwarding}" "${remote_command}" "${ssh_args[@]}"
}

main "$@"
