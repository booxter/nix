#!/usr/bin/env bash
# shellcheck shell=bash

set -euo pipefail

program_name="${DIFF_CONFIG_PROGRAM_NAME:-diff-config}"

usage() {
  cat <<EOF
Usage: ${program_name} <machine> <old-rev> <new-rev>

Build the NixOS or nix-darwin configuration for <machine> at two Git revisions
with nh, then render the package and closure-size diff with dix, the diff
backend used by nh.

Examples:
  ${program_name} frame origin/master HEAD
  ${program_name} mair origin/master HEAD
  ${program_name} prox-srvarrvm 1a2b3c4 5d6e7f8
EOF
}

parse_target() {
  local attr="$1"

  attr="${attr#\#}"
  attr="${attr#.#}"
  attr="${attr#.}"

  if [[ "${attr}" == nixosConfigurations.* ]]; then
    target_kind="nixos"
    attr="${attr#nixosConfigurations.}"
    attr="${attr%%.*}"
  elif [[ "${attr}" == darwinConfigurations.* ]]; then
    target_kind="darwin"
    attr="${attr#darwinConfigurations.}"
    attr="${attr%%.*}"
  else
    target_kind=""
  fi

  if [[ -z "${attr}" ]]; then
    echo "machine must not be empty" >&2
    return 1
  fi

  machine="${attr}"
}

resolve_git_rev() {
  local label="$1"
  local rev="$2"
  local resolved=""

  if ! resolved="$(git -C "${repo_root}" rev-parse --verify "${rev}^{commit}" 2>/dev/null)"; then
    echo "Unable to resolve ${label} revision '${rev}' in ${repo_root}." >&2
    return 1
  fi

  printf '%s\n' "${resolved}"
}

flake_ref_for_rev() {
  local rev="$1"

  printf 'git+file://%s?rev=%s\n' "${repo_root}" "${rev}"
}

detect_target_kind() {
  local label="$1"
  local flake_ref="$2"
  local detected=""

  if ! detected="$(
    DIFF_CONFIG_FLAKE_REF="${flake_ref}" DIFF_CONFIG_MACHINE="${machine}" \
      nix --extra-experimental-features "nix-command flakes" eval --impure --raw --expr '
        let
          f = builtins.getFlake (builtins.getEnv "DIFF_CONFIG_FLAKE_REF");
          name = builtins.getEnv "DIFF_CONFIG_MACHINE";
          hasNixos =
            f ? nixosConfigurations
            && builtins.hasAttr name f.nixosConfigurations;
          hasDarwin =
            f ? darwinConfigurations
            && builtins.hasAttr name f.darwinConfigurations;
        in
          if hasNixos then "nixos"
          else if hasDarwin then "darwin"
          else "missing"
      '
  )"; then
    echo "Unable to inspect ${label} revision for machine '${machine}'." >&2
    return 1
  fi

  printf '%s\n' "${detected}"
}

resolve_target_kind() {
  local old_kind=""
  local new_kind=""

  if [[ -n "${target_kind}" ]]; then
    return 0
  fi

  old_kind="$(detect_target_kind old "${old_flake}")"
  new_kind="$(detect_target_kind new "${new_flake}")"

  if [[ "${old_kind}" == "missing" || "${new_kind}" == "missing" ]]; then
    echo "Machine '${machine}' must exist in both revisions." >&2
    echo "old revision: ${old_kind}; new revision: ${new_kind}" >&2
    return 1
  fi

  if [[ "${old_kind}" != "${new_kind}" ]]; then
    echo "Machine '${machine}' changed configuration kind between revisions." >&2
    echo "old revision: ${old_kind}; new revision: ${new_kind}" >&2
    return 1
  fi

  target_kind="${new_kind}"
}

build_config() {
  local label="$1"
  local rev="$2"
  local flake_ref="$3"
  local out_link="$4"
  local nh_kind=""

  case "${target_kind}" in
    nixos) nh_kind="os" ;;
    darwin) nh_kind="darwin" ;;
    *)
      echo "Unsupported target kind: ${target_kind}" >&2
      return 1
      ;;
  esac

  local -a nh_cmd=(
    nh
    "${nh_kind}"
    build
    --no-nom
    --diff
    never
    --hostname
    "${machine}"
    --out-link
    "${out_link}"
    --print-build-logs
    --show-trace
    "${flake_ref}"
  )

  echo "Building ${target_kind} configuration ${machine} at ${label} (${rev})" >&2
  "${nh_cmd[@]}" >&2
}

filter_dix_output() {
  local seen_output=false
  local line=""

  while IFS= read -r line; do
    case "${line}" in
      "<<< "*|">>> "*) continue ;;
    esac

    if [[ "${seen_output}" == false && -z "${line}" ]]; then
      continue
    fi

    seen_output=true
    printf '%s\n' "${line}"
  done
}

if [[ "$#" -eq 1 && ( "$1" == "-h" || "$1" == "--help" ) ]]; then
  usage
  exit 0
fi

if [[ "$#" -ne 3 ]]; then
  usage >&2
  exit 1
fi

machine=""
target_kind=""
parse_target "$1"
old_input="$2"
new_input="$3"

repo_root="${DIFF_CONFIG_REPO_ROOT:-}"
if [[ -z "${repo_root}" ]]; then
  if ! repo_root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
    echo "Unable to find a Git checkout; run from the flake repo or set DIFF_CONFIG_REPO_ROOT." >&2
    exit 1
  fi
fi

if ! repo_root="$(cd "${repo_root}" && pwd -P)"; then
  echo "Unable to access repo root: ${repo_root}" >&2
  exit 1
fi

if [[ ! -f "${repo_root}/flake.nix" ]]; then
  echo "Repo root does not contain flake.nix: ${repo_root}" >&2
  exit 1
fi

old_rev="$(resolve_git_rev old "${old_input}")"
new_rev="$(resolve_git_rev new "${new_input}")"

old_flake="$(flake_ref_for_rev "${old_rev}")"
new_flake="$(flake_ref_for_rev "${new_rev}")"

resolve_target_kind

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/diff-config.XXXXXX")"
cleanup() {
  if [[ "${DIFF_CONFIG_KEEP_TMP:-}" == "1" ]]; then
    echo "Keeping temporary output links in ${tmpdir}" >&2
  else
    rm -rf "${tmpdir}"
  fi
}
trap cleanup EXIT

old_link="${tmpdir}/old"
new_link="${tmpdir}/new"

build_config old "${old_rev}" "${old_flake}" "${old_link}"
build_config new "${new_rev}" "${new_flake}" "${new_link}"

echo "Diffing ${target_kind} configuration ${machine}: ${old_rev} -> ${new_rev}" >&2
dix "${old_link}" "${new_link}" | filter_dix_output
