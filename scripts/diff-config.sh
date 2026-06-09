#!/usr/bin/env bash
# shellcheck shell=bash

set -euo pipefail

program_name="${DIFF_CONFIG_PROGRAM_NAME:-diff-config}"

usage() {
  cat <<EOF
Usage: ${program_name} [--details] [--path <relpath>] <machine> <old-rev> <new-rev>

Build the NixOS or nix-darwin configuration for <machine> at two Git revisions
with nh, then render the package and closure-size diff with dix, the diff
backend used by nh.

With --details, also diff generated target configuration files from the built
toplevels and embedded Home Manager users. By default this covers:
  NixOS:       etc, activate, bin/switch-to-configuration
  nix-darwin:  etc, activate, activate-user, Library/LaunchAgents, Library/LaunchDaemons, user/Library/LaunchAgents
  Home Manager users: activate, home-files, LaunchAgents, session-vars
  Profile/manpage trees and release metadata files are skipped because those
  changes are already covered by the dix output.

Repeat --path with --details to override the default system generated paths.

Examples:
  ${program_name} frame origin/master HEAD
  ${program_name} --details frame origin/master HEAD
  ${program_name} --details --path etc/nix/nix.conf frame origin/master HEAD
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

validate_relpath() {
  local relpath="$1"

  case "${relpath}" in
    "" | /* | .. | ../* | */.. | */../*)
      echo "generated path must be a relative path without '..': ${relpath}" >&2
      return 1
      ;;
  esac
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

resolve_machine_alias() {
  local resolved=""

  if [[ "${target_kind}" == "darwin" ]]; then
    return 0
  fi

  # shellcheck disable=SC2016
  if ! resolved="$(
    DIFF_CONFIG_REPO_ROOT="${repo_root}" DIFF_CONFIG_MACHINE="${machine}" \
      DIFF_CONFIG_RESOLVE_MACHINE_ALIAS=1 \
      nix --extra-experimental-features "nix-command flakes" eval --impure --raw --expr '
        let
          repoRoot = builtins.getEnv "DIFF_CONFIG_REPO_ROOT";
          name = builtins.getEnv "DIFF_CONFIG_MACHINE";
          f = builtins.getFlake repoRoot;
          inventory = import "${repoRoot}/lib/inventory.nix" {
            lib = f.inputs.nixpkgs.lib;
          };
          specName = inventory.nixosConfigNameToSpecName name;
        in
          if builtins.hasAttr specName inventory.nixosHostSpecsByName then
            inventory.toNixosConfigName inventory.nixosHostSpecsByName.${specName}
          else
            name
      '
  )"; then
    echo "Unable to resolve machine alias '${machine}' from current inventory." >&2
    return 1
  fi

  machine="${resolved}"
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

default_generated_paths() {
  if [[ "${#generated_paths[@]}" -gt 0 ]]; then
    return 0
  fi

  case "${target_kind}" in
    nixos)
      generated_paths=(etc)
      ;;
    darwin)
      generated_paths=(
        etc
        Library/LaunchAgents
        Library/LaunchDaemons
        user/Library/LaunchAgents
      )
      ;;
    *)
      echo "Unsupported target kind: ${target_kind}" >&2
      return 1
      ;;
  esac
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

normalize_store_paths() {
  sed -E "s#/nix/store/[0-9a-z]{32}\\\\-[^/[:space:]'\"<>]+#/nix/store/<path>#g; s#/nix/store/[0-9a-z]{32}-[^/[:space:]'\"<>]+#/nix/store/<path>#g"
}

diff_supports_color() {
  diff --color=never -q /dev/null /dev/null >/dev/null 2>&1
}

run_recursive_diff() {
  local diff_root="$1"
  local -a diff_cmd=(diff -ruN)

  if [[ -n "${detail_diff_color}" ]] && diff_supports_color; then
    diff_cmd=(diff "--color=${detail_diff_color}" -ruN)
  fi

  (cd "${diff_root}" && "${diff_cmd[@]}" old new)
}

generated_path_exists() {
  local root="$1"
  local relpath="$2"
  local path="${root}/${relpath}"

  [[ -e "${path}" || -L "${path}" ]]
}

should_skip_generated_source() {
  local source="$1"

  case "${source}" in
    */etc/profiles | */etc/profiles/* | */share/man | */share/man/* | \
      */etc/issue | */etc/issue.net | */etc/os-release | */etc/lsb-release)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

copy_generated_path() {
  local source_root="$1"
  local dest_root="$2"
  local relpath="$3"
  local source="${source_root}/${relpath}"
  local dest="${dest_root}/${relpath}"
  local parent="${relpath%/*}"

  if ! generated_path_exists "${source_root}" "${relpath}"; then
    return 0
  fi

  if should_skip_generated_source "${source}"; then
    return 0
  fi

  if [[ "${parent}" != "${relpath}" ]]; then
    mkdir -p "${dest_root}/${parent}"
  fi

  copy_generated_node "${source}" "${dest}"
}

copy_generated_store_path() {
  local source="$1"
  local dest_root="$2"
  local relpath="$3"
  local dest="${dest_root}/${relpath}"
  local parent="${relpath%/*}"

  if [[ -z "${source}" || (! -e "${source}" && ! -L "${source}") ]]; then
    return 0
  fi

  if should_skip_generated_source "${source}"; then
    return 0
  fi

  if [[ "${parent}" != "${relpath}" ]]; then
    mkdir -p "${dest_root}/${parent}"
  fi

  copy_generated_node "${source}" "${dest}"
}

copy_generated_directory() {
  local source="$1"
  local dest="$2"
  local entry=""

  mkdir -p "${dest}"

  for entry in "${source}"/* "${source}"/.[!.]* "${source}"/..?*; do
    if [[ ! -e "${entry}" && ! -L "${entry}" ]]; then
      continue
    fi

    if should_skip_generated_source "${entry}"; then
      continue
    fi

    copy_generated_node "${entry}" "${dest}/$(basename "${entry}")"
  done
}

copy_generated_node() {
  local source="$1"
  local dest="$2"
  local target=""

  if [[ -L "${source}" && ! -e "${source}" ]]; then
    target="$(readlink "${source}")"
    printf 'broken symlink -> %s\n' "${target}" | normalize_store_paths >"${dest}"
  elif [[ -d "${source}" ]]; then
    copy_generated_directory "${source}" "${dest}"
  else
    cp -p "${source}" "${dest}"
    if LC_ALL=C grep -Iq . "${source}"; then
      chmod u+w "${dest}"
      normalize_store_paths <"${source}" >"${dest}"
    fi
  fi
}

materialize_generated_paths() {
  local source_root="$1"
  local dest_root="$2"
  local relpath=""

  mkdir -p "${dest_root}"

  for relpath in "${generated_paths[@]}"; do
    copy_generated_path "${source_root}" "${dest_root}" "${relpath}"
  done
}

materialize_system_details() {
  local old_detail_root="$1"
  local new_detail_root="$2"
  local relpath=""
  local found_any=false
  local -a artifact_paths=(
    activate
  )

  case "${target_kind}" in
    nixos)
      artifact_paths+=(
        bin/switch-to-configuration
      )
      ;;
    darwin)
      artifact_paths+=(
        activate-user
      )
      ;;
  esac

  for relpath in "${generated_paths[@]}"; do
    if generated_path_exists "${old_link}" "${relpath}" || generated_path_exists "${new_link}" "${relpath}"; then
      found_any=true
    else
      echo "Skipping missing generated path in both revisions: ${relpath}" >&2
    fi
  done

  for relpath in "${artifact_paths[@]}"; do
    if generated_path_exists "${old_link}" "${relpath}" || generated_path_exists "${new_link}" "${relpath}"; then
      found_any=true
    fi
  done

  if [[ "${found_any}" == false ]]; then
    return 0
  fi

  materialize_generated_paths "${old_link}" "${old_detail_root}/system"
  materialize_generated_paths "${new_link}" "${new_detail_root}/system"

  for relpath in "${artifact_paths[@]}"; do
    copy_generated_path "${old_link}" "${old_detail_root}/system" "${relpath}"
    copy_generated_path "${new_link}" "${new_detail_root}/system" "${relpath}"
  done

  detail_found=true
}

eval_home_manager_users() {
  local label="$1"
  local flake_ref="$2"
  local users=""

  if ! users="$(
    DIFF_CONFIG_FLAKE_REF="${flake_ref}" \
      DIFF_CONFIG_MACHINE="${machine}" \
      DIFF_CONFIG_TARGET_KIND="${target_kind}" \
      nix --extra-experimental-features "nix-command flakes" eval --impure --raw --expr '
        let
          f = builtins.getFlake (builtins.getEnv "DIFF_CONFIG_FLAKE_REF");
          kind = builtins.getEnv "DIFF_CONFIG_TARGET_KIND";
          name = builtins.getEnv "DIFF_CONFIG_MACHINE";
          configs =
            if kind == "nixos" then f.nixosConfigurations
            else if kind == "darwin" then f.darwinConfigurations
            else { };
          cfg = builtins.getAttr name configs;
          hm =
            if builtins.hasAttr "home-manager" cfg.config
            then cfg.config."home-manager"
            else { };
          users =
            if builtins.hasAttr "users" hm
            then builtins.attrNames hm.users
            else [ ];
        in
          builtins.concatStringsSep "\n" users
      '
  )"; then
    echo "Unable to inspect Home Manager users in ${label} revision for machine '${machine}'." >&2
    return 1
  fi

  printf '%s\n' "${users}"
}

add_home_manager_user() {
  local user="$1"
  local existing=""

  for existing in "${home_manager_users[@]}"; do
    if [[ "${existing}" == "${user}" ]]; then
      return 0
    fi
  done

  home_manager_users+=("${user}")
}

array_contains() {
  local needle="$1"
  local item=""
  shift

  for item in "$@"; do
    if [[ "${item}" == "${needle}" ]]; then
      return 0
    fi
  done

  return 1
}

load_home_manager_users() {
  local label="$1"
  local flake_ref="$2"
  local users_text=""
  local user=""

  users_text="$(eval_home_manager_users "${label}" "${flake_ref}")"

  while IFS= read -r user; do
    if [[ -z "${user}" ]]; then
      continue
    fi

    case "${label}" in
      old) old_home_manager_users+=("${user}") ;;
      new) new_home_manager_users+=("${user}") ;;
      *)
        echo "Unsupported Home Manager side: ${label}" >&2
        return 1
        ;;
    esac

    add_home_manager_user "${user}"
  done <<<"${users_text}"
}

build_home_manager_activation() {
  local label="$1"
  local rev="$2"
  local flake_ref="$3"
  local user="$4"
  local activation=""

  if ! activation="$(
    DIFF_CONFIG_FLAKE_REF="${flake_ref}" \
      DIFF_CONFIG_MACHINE="${machine}" \
      DIFF_CONFIG_TARGET_KIND="${target_kind}" \
      DIFF_CONFIG_HM_USER="${user}" \
      nix --extra-experimental-features "nix-command flakes" build \
        --impure \
        --no-link \
        --print-out-paths \
        --expr '
          let
            f = builtins.getFlake (builtins.getEnv "DIFF_CONFIG_FLAKE_REF");
            kind = builtins.getEnv "DIFF_CONFIG_TARGET_KIND";
            name = builtins.getEnv "DIFF_CONFIG_MACHINE";
            user = builtins.getEnv "DIFF_CONFIG_HM_USER";
            configs =
              if kind == "nixos" then f.nixosConfigurations
              else if kind == "darwin" then f.darwinConfigurations
              else { };
            cfg = builtins.getAttr name configs;
          in
            (builtins.getAttr user cfg.config."home-manager".users).home.activationPackage
        '
  )"; then
    echo "Unable to build Home Manager activation package for ${user} in ${label} revision." >&2
    return 1
  fi

  printf '%s\n' "${activation}"
}

build_home_manager_session_variables() {
  local label="$1"
  local rev="$2"
  local flake_ref="$3"
  local user="$4"
  local session_variables=""

  if ! session_variables="$(
    DIFF_CONFIG_FLAKE_REF="${flake_ref}" \
      DIFF_CONFIG_MACHINE="${machine}" \
      DIFF_CONFIG_TARGET_KIND="${target_kind}" \
      DIFF_CONFIG_HM_USER="${user}" \
      nix --extra-experimental-features "nix-command flakes" build \
        --impure \
        --no-link \
        --print-out-paths \
        --expr '
          let
            f = builtins.getFlake (builtins.getEnv "DIFF_CONFIG_FLAKE_REF");
            kind = builtins.getEnv "DIFF_CONFIG_TARGET_KIND";
            name = builtins.getEnv "DIFF_CONFIG_MACHINE";
            user = builtins.getEnv "DIFF_CONFIG_HM_USER";
            configs =
              if kind == "nixos" then f.nixosConfigurations
              else if kind == "darwin" then f.darwinConfigurations
              else { };
            cfg = builtins.getAttr name configs;
          in
            (builtins.getAttr user cfg.config."home-manager".users).home.sessionVariablesPackage
        '
  )"; then
    echo "Unable to build Home Manager session variables package for ${user} in ${label} revision." >&2
    return 1
  fi

  printf '%s\n' "${session_variables}"
}

materialize_home_manager_paths() {
  local activation="$1"
  local dest_root="$2"
  local relpath=""

  mkdir -p "${dest_root}"

  if [[ -z "${activation}" ]]; then
    return 0
  fi

  for relpath in "${home_manager_generated_paths[@]}"; do
    copy_generated_path "${activation}" "${dest_root}" "${relpath}"
  done
}

materialize_home_manager_user_details() {
  local user="$1"
  local old_detail_root="$2"
  local new_detail_root="$3"
  local old_activation=""
  local new_activation=""
  local old_session_variables=""
  local new_session_variables=""
  local old_tree="${old_detail_root}/home-manager/${user}"
  local new_tree="${new_detail_root}/home-manager/${user}"

  if array_contains "${user}" "${old_home_manager_users[@]}"; then
    old_activation="$(build_home_manager_activation old "${old_rev}" "${old_flake}" "${user}")"
    old_session_variables="$(build_home_manager_session_variables old "${old_rev}" "${old_flake}" "${user}")"
  else
    echo "Home Manager user ${user} is missing in old revision; diffing against an empty tree." >&2
  fi

  if array_contains "${user}" "${new_home_manager_users[@]}"; then
    new_activation="$(build_home_manager_activation new "${new_rev}" "${new_flake}" "${user}")"
    new_session_variables="$(build_home_manager_session_variables new "${new_rev}" "${new_flake}" "${user}")"
  else
    echo "Home Manager user ${user} is missing in new revision; diffing against an empty tree." >&2
  fi

  materialize_home_manager_paths "${old_activation}" "${old_tree}"
  materialize_home_manager_paths "${new_activation}" "${new_tree}"
  copy_generated_store_path "${old_session_variables}" "${old_tree}" session-vars
  copy_generated_store_path "${new_session_variables}" "${new_tree}" session-vars
  detail_found=true
}

materialize_home_manager_details() {
  local old_detail_root="$1"
  local new_detail_root="$2"
  local user=""

  old_home_manager_users=()
  new_home_manager_users=()
  home_manager_users=()
  home_manager_generated_paths=(
    activate
    home-files
    LaunchAgents
  )

  load_home_manager_users old "${old_flake}"
  load_home_manager_users new "${new_flake}"

  if [[ "${#home_manager_users[@]}" -eq 0 ]]; then
    return 0
  fi

  for user in "${home_manager_users[@]}"; do
    materialize_home_manager_user_details "${user}" "${old_detail_root}" "${new_detail_root}"
  done
}

run_detail_diff() {
  local diff_root="${tmpdir}/details"
  local old_detail_root="${diff_root}/old"
  local new_detail_root="${diff_root}/new"
  local diff_status=0

  detail_found=false
  mkdir -p "${old_detail_root}" "${new_detail_root}"

  materialize_system_details "${old_detail_root}" "${new_detail_root}"
  materialize_home_manager_details "${old_detail_root}" "${new_detail_root}"

  if [[ "${detail_found}" == false ]]; then
    echo "No generated detail paths found." >&2
    return 1
  fi

  set +e
  run_recursive_diff "${diff_root}"
  diff_status="$?"
  set -e

  if [[ "${diff_status}" -eq 0 ]]; then
    printf 'No generated config differences.\n'
    return 0
  fi

  if [[ "${diff_status}" -eq 1 ]]; then
    return 0
  fi

  return "${diff_status}"
}

details=false
generated_paths=()
args=()

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --details)
      details=true
      shift
      ;;
    --path)
      if [[ -z "${2:-}" ]]; then
        echo "--path requires an argument" >&2
        exit 1
      fi
      validate_relpath "$2"
      details=true
      generated_paths+=("$2")
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    --)
      shift
      while [[ "$#" -gt 0 ]]; do
        args+=("$1")
        shift
      done
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      args+=("$1")
      shift
      ;;
  esac
done

if [[ "${#args[@]}" -ne 3 ]]; then
  usage >&2
  exit 1
fi

machine=""
target_kind=""
parse_target "${args[0]}"
old_input="${args[1]}"
new_input="${args[2]}"

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

resolve_machine_alias

old_rev="$(resolve_git_rev old "${old_input}")"
new_rev="$(resolve_git_rev new "${new_input}")"

old_flake="$(flake_ref_for_rev "${old_rev}")"
new_flake="$(flake_ref_for_rev "${new_rev}")"

resolve_target_kind
if [[ "${details}" == true ]]; then
  default_generated_paths
fi

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/diff-config.XXXXXX")"
cleanup() {
  if [[ "${DIFF_CONFIG_KEEP_TMP:-}" == "1" ]]; then
    echo "Keeping temporary output links in ${tmpdir}" >&2
  else
    chmod -R u+rwX "${tmpdir}" 2>/dev/null || true
    rm -rf "${tmpdir}"
  fi
}
trap cleanup EXIT

old_link="${tmpdir}/old"
new_link="${tmpdir}/new"
dix_color="${DIFF_CONFIG_DIX_COLOR:-auto}"
detail_diff_color="${DIFF_CONFIG_DIFF_COLOR:-}"

if [[ -z "${DIFF_CONFIG_DIX_COLOR:-}" && -t 1 ]]; then
  dix_color="always"
fi

if [[ -z "${DIFF_CONFIG_DIFF_COLOR:-}" && -t 1 ]]; then
  detail_diff_color="always"
fi

build_config old "${old_rev}" "${old_flake}" "${old_link}"
build_config new "${new_rev}" "${new_flake}" "${new_link}"

echo "Diffing ${target_kind} configuration ${machine}: ${old_rev} -> ${new_rev}" >&2
dix --color "${dix_color}" "${old_link}" "${new_link}" | filter_dix_output

if [[ "${details}" == true ]]; then
  run_detail_diff
fi
