#!/usr/bin/env bash
# shellcheck shell=bash

set -euo pipefail

program_name="${XRUN_NIXPKGS_PROGRAM_NAME:-xrun-nixpkgs}"

usage() {
  cat <<EOF
Usage: ${program_name} [options] <pr-or-flake-ref> <package-attr> [-- program-args...]

Build a Linux package on a remote host and run it through SSH X11 forwarding.

PR shortcuts are resolved against NixOS/nixpkgs:
  ${program_name} 538891 podman-desktop
  ${program_name} https://github.com/NixOS/nixpkgs/pull/538891 podman-desktop

Flake refs are accepted as-is:
  ${program_name} github:NixOS/nixpkgs/nixos-unstable podman-desktop

Options:
  --host HOST       SSH host to build and run on (default: frame)
  --cmd NAME        Run \$out/bin/NAME instead of auto-detecting mainProgram
  --allow-unfree    Set NIXPKGS_ALLOW_UNFREE=1 for the remote nix commands
  --trusted         Use trusted X11 forwarding (-Y) instead of -X
  --ssh-option OPT  Pass one -o option to ssh; repeat as needed
  --dry-run         Print the resolved installable and SSH target, then exit
  --help            Show this help
EOF
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

main() {
  local host="${XRUN_NIXPKGS_HOST:-frame}"
  local command=""
  local allow_unfree="${XRUN_NIXPKGS_ALLOW_UNFREE:-false}"
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
    printf 'x11 forwarding: %s\n' "${forwarding}"
    printf 'installable: %s#%s\n' "${flake_ref}" "${package_attr}"
    printf 'command: %s\n' "${command:-auto}"
    printf 'allow unfree: %s\n' "${allow_unfree}"
    exit 0
  fi

  exec ssh "${forwarding}" "${ssh_args[@]}" "${host}" bash -s -- \
    "${flake_ref}" \
    "${package_attr}" \
    "${command}" \
    "${allow_unfree}" \
    "$@" <<'REMOTE'
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

main "$@"
