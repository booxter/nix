#!/usr/bin/env bash
set -euo pipefail

deploy_flake_ref() {
  if git rev-parse --show-toplevel >/dev/null 2>&1; then
    printf '.'
  else
    printf 'path:.'
  fi
}

merge_latest_master() {
  local repo_dir="$1"
  local branch="$2"

  echo "Merging latest origin/master into ${branch}."
  GIT_CONFIG_NOSYSTEM=1 \
    GIT_CONFIG_GLOBAL=/dev/null \
    GIT_CONFIG_SYSTEM=/dev/null \
    GIT_TERMINAL_PROMPT=0 \
    git -C "$repo_dir" fetch origin master
  GIT_CONFIG_NOSYSTEM=1 \
    GIT_CONFIG_GLOBAL=/dev/null \
    GIT_CONFIG_SYSTEM=/dev/null \
    git -C "$repo_dir" \
      -c user.name="Nix deploy" \
      -c user.email="nix-deploy@localhost" \
      -c commit.gpgSign=false \
      merge --no-edit --no-gpg-sign FETCH_HEAD
}

run_nh_from_repo() {
  local flake_ref
  flake_ref="$(deploy_flake_ref)"
  nix shell --inputs-from "$flake_ref" nixpkgs#nh nixpkgs#nix-output-monitor -c nh "$@"
}

run_nh_for_host_from_repo() {
  local platform="$1"
  local action="$2"
  local host_name="$3"
  local flake_ref
  shift 3

  flake_ref="$(deploy_flake_ref)"
  run_nh_from_repo "$platform" "$action" \
    --hostname "$host_name" \
    "$@" \
    --print-build-logs \
    --show-trace \
    "${flake_ref}#"
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

  run_nh_for_host_from_repo os "$rebuild_action" "$host_name"
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

  if run_nh_for_host_from_repo darwin build "$host_name" \
    --out-link "$out_link" \
    --diff auto; then
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
