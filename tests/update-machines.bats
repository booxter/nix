#!/usr/bin/env bats

setup() {
  source ./apps/_helpers/update-machines-lib.sh
}

write_update_machines_test_stubs() {
  local stub_dir="$1"
  local bash_path
  bash_path="$(command -v bash)"

  {
    printf '#!%s\n' "$bash_path"
    cat <<'EOF'
set -euo pipefail
if [[ "${1-}" == "build" ]]; then
  if [[ -n "${NIX_BUILD_ARGS_OUT:-}" ]]; then
    printf '%s\n' "$*" > "$NIX_BUILD_ARGS_OUT"
  fi
elif [[ "$*" == *"hostInventory.site.lan.gateway.address"* ]]; then
  printf '%s\n' '127.0.0.1'
elif [[ "$*" == *"hostWorkMap"* ]]; then
  printf '%s\n' '{"darwin":{},"nixos":{"alpha":false,"beta":false,"gamma":false,"nv":true}}'
elif [[ "$*" == *"hostInventory = import ./lib/inventory.nix"* ]]; then
  printf '%s\n' '{"alpha":"alpha","beta":"beta","gamma":"gamma","nv":"nv"}'
else
  echo "unexpected nix invocation: $*" >&2
  exit 99
fi
EOF
  } > "$stub_dir/nix"
  chmod +x "$stub_dir/nix"

  {
    printf '#!%s\n' "$bash_path"
    cat <<'EOF'
set -euo pipefail
exit 0
EOF
  } > "$stub_dir/dig"
  chmod +x "$stub_dir/dig"

  {
    printf '#!%s\n' "$bash_path"
    cat <<'EOF'
set -euo pipefail
case "${1-}" in
  -s)
    printf '%s\n' "controller"
    ;;
  -f)
    printf '%s\n' "controller.example.test"
    ;;
  *)
    printf '%s\n' "controller"
    ;;
esac
EOF
  } > "$stub_dir/hostname"
  chmod +x "$stub_dir/hostname"

  {
    printf '#!%s\n' "$bash_path"
    cat <<'EOF'
set -euo pipefail

if [[ "${1-}" == "-G" ]]; then
  exit 0
fi

args=("$@")
host=""
cmd_start="${#args[@]}"
i=0
while [[ $i -lt ${#args[@]} ]]; do
  arg="${args[$i]}"
  case "$arg" in
    -tt|-t|-n)
      i=$((i + 1))
      ;;
    -o)
      i=$((i + 2))
      ;;
    -*)
      i=$((i + 1))
      ;;
    *)
      host="$arg"
      cmd_start=$((i + 1))
      break
      ;;
  esac
done

if [[ -z "$host" ]]; then
  echo "ssh stub: missing host in $*" >&2
  exit 98
fi

cmd=("${args[@]:$cmd_start}")
joined="${cmd[*]}"

if [[ "$joined" == "true" ]]; then
  if [[ "${SSH_TEST_MODE:-}" == "unreachable" ]]; then
    exit 1
  fi
  exit 0
fi

if [[ "$joined" == cat\ \>* ]]; then
  if [[ -n "${SSH_UPLOADED_SCRIPT_OUT:-}" ]]; then
    cat > "$SSH_UPLOADED_SCRIPT_OUT"
  else
    cat >/dev/null
  fi
  exit 0
fi

case "${SSH_TEST_MODE:-}" in
  deploy-fail)
    case "$host" in
      alpha|beta)
        exit 1
        ;;
      *)
        exit 0
        ;;
    esac
    ;;
  unreachable)
    echo "ssh stub: unexpected command in unreachable mode: $joined" >&2
    exit 97
    ;;
  *)
    exit 0
    ;;
esac
EOF
  } > "$stub_dir/ssh"
  chmod +x "$stub_dir/ssh"

}

@test "calc_min_disk_kb_from_gib converts GiB to KiB" {
  run calc_min_disk_kb_from_gib 20
  [ "$status" -eq 0 ]
  [ "$output" = "20971520" ]
}

@test "lan_dns_lookup_candidates adds the LAN domain for bare hostnames" {
  run lan_dns_lookup_candidates beast home.arpa
  [ "$status" -eq 0 ]
  expected=$'beast\nbeast.home.arpa'
  [ "$output" = "$expected" ]
}

@test "lan_dns_lookup_candidates leaves FQDNs unchanged" {
  run lan_dns_lookup_candidates beast.home.arpa home.arpa
  [ "$status" -eq 0 ]
  [ "$output" = "beast.home.arpa" ]
}

@test "lan_dns_lookup_candidates leaves IPv4 addresses unchanged" {
  run lan_dns_lookup_candidates 192.168.15.10 home.arpa
  [ "$status" -eq 0 ]
  [ "$output" = "192.168.15.10" ]
}

@test "resolve_base_host leaves bare-metal hosts unchanged" {
  export HOST_BASE_MAP_JSON='{"beast":"beast"}'
  run resolve_base_host beast
  [ "$status" -eq 0 ]
  [ "$output" = "beast" ]
}

@test "resolve_base_host leaves other hosts unchanged" {
  export HOST_BASE_MAP_JSON='{"beast":"beast"}'
  run resolve_base_host nvws
  [ "$status" -eq 0 ]
  [ "$output" = "nvws" ]
}

@test "resolve_runtime_host can differ from connection host" {
  export HOST_RUNTIME_MAP_JSON='{"fana":"prox-fanavm"}'
  run resolve_runtime_host fana
  [ "$status" -eq 0 ]
  [ "$output" = "prox-fanavm" ]
}

@test "resolve_host_alias maps host aliases" {
  export HOST_ALIAS_MAP_JSON='{"org":"org","beast":"beast"}'
  run resolve_host_alias org
  [ "$status" -eq 0 ]
  [ "$output" = "org" ]
}

@test "canonicalize_hosts preserves order after alias resolution" {
  export HOST_ALIAS_MAP_JSON='{"org":"org","srvarr":"srvarr","beast":"beast"}'
  run canonicalize_hosts org beast srvarr
  [ "$status" -eq 0 ]
  expected=$'org\nbeast\nsrvarr'
  [ "$output" = "$expected" ]
}

@test "display_host_name keeps canonical short VM configs displayable" {
  export HOST_DISPLAY_MAP_JSON='{"org":"org","srvarr":"srvarr","beast":"beast"}'
  run display_host_name org
  [ "$status" -eq 0 ]
  [ "$output" = "org" ]
}

@test "format_display_host_list joins display names" {
  export HOST_DISPLAY_MAP_JSON='{"org":"org","srvarr":"srvarr","beast":"beast"}'
  run format_display_host_list org beast srvarr
  [ "$status" -eq 0 ]
  [ "$output" = "org, beast, srvarr" ]
}

@test "hosts_from_work_map returns sorted unique hosts" {
  work_map='{"darwin":{"mmini":false},"nixos":{"beast":false,"nvws":true}}'
  run hosts_from_work_map "$work_map"
  [ "$status" -eq 0 ]
  expected=$'beast\nmmini\nnvws'
  [ "$output" = "$expected" ]
}

@test "host_kind_from_work_map identifies NixOS and Darwin hosts" {
  work_map='{"darwin":{"mair":false},"nixos":{"frame":false}}'

  run host_kind_from_work_map frame "$work_map"
  [ "$status" -eq 0 ]
  [ "$output" = "nixos" ]

  run host_kind_from_work_map mair "$work_map"
  [ "$status" -eq 0 ]
  [ "$output" = "darwin" ]

  run host_kind_from_work_map missing "$work_map"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "host_metadata_from_work_map returns kind and work status together" {
  work_map='{"darwin":{"mair":true},"nixos":{"frame":false}}'

  run host_metadata_from_work_map frame "$work_map"
  [ "$status" -eq 0 ]
  [ "$output" = $'nixos\tfalse' ]

  run host_metadata_from_work_map mair "$work_map"
  [ "$status" -eq 0 ]
  [ "$output" = $'darwin\ttrue' ]
}

@test "filter_hosts_by_mode includes only personal hosts" {
  work_map='{"darwin":{"mmini":false},"nixos":{"beast":false,"nvws":true}}'
  run filter_hosts_by_mode personal "$work_map" nvws beast mmini
  [ "$status" -eq 0 ]
  expected=$'beast\nmmini'
  [ "$output" = "$expected" ]
}

@test "filter_hosts_by_mode includes only work hosts" {
  work_map='{"darwin":{"mmini":false},"nixos":{"beast":false,"nvws":true}}'
  run filter_hosts_by_mode work "$work_map" nvws beast mmini
  [ "$status" -eq 0 ]
  expected=$'nvws'
  [ "$output" = "$expected" ]
}

@test "filter_hosts_by_mode includes all hosts for both" {
  run filter_hosts_by_mode both 'not parsed in both mode' nvws beast mmini
  [ "$status" -eq 0 ]
  expected=$'nvws\nbeast\nmmini'
  [ "$output" = "$expected" ]
}

@test "prioritize_hosts orders priority, normal, deferred" {
  run prioritize_hosts cache nvws zeta prx2-lab alpha
  [ "$status" -eq 0 ]
  expected=$'nvws\nprx2-lab\nzeta\nalpha\ncache'
  [ "$output" = "$expected" ]
}

@test "format_host_list joins hosts with commas" {
  run format_host_list alpha beta gamma
  [ "$status" -eq 0 ]
  [ "$output" = "alpha, beta, gamma" ]
}

@test "prebuild_deploy_targets builds NixOS and Darwin closures from the requested branch" {
  workdir="$BATS_TMPDIR/prebuild-deploy-targets"
  mkdir -p "$workdir/bin"
  bash_path="$(command -v bash)"

  {
    printf '#!%s\n' "$bash_path"
    cat <<'EOF'
set -euo pipefail
printf '%s\n' "$*" > "$NIX_BUILD_ARGS_OUT"
EOF
  } > "$workdir/bin/nix"
  chmod +x "$workdir/bin/nix"

  export PATH="$workdir/bin:$PATH"
  export NIX_BUILD_ARGS_OUT="$workdir/nix.args"
  work_map='{"nixos":{"frame":false},"darwin":{"mair":false}}'

  run prebuild_deploy_targets feature/test github.com:booxter/nix "$work_map" frame mair

  [ "$status" -eq 0 ]
  [ "$(<"$NIX_BUILD_ARGS_OUT")" = "build -L --show-trace --no-link git+https://github.com/booxter/nix.git?ref=feature/test#nixosConfigurations.frame.config.system.build.toplevel git+https://github.com/booxter/nix.git?ref=feature/test#darwinConfigurations.mair.system" ]
}

@test "deploy_installable_for_host rejects hosts absent from the work map" {
  run deploy_installable_for_host .# missing '{"nixos":{},"darwin":{}}'

  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown host: missing"* ]]
}

@test "run_nixos_rebuild_from_repo uses pinned nh for switch and boot" {
  workdir="$BATS_TMPDIR/nixos-nh-action"
  mkdir -p "$workdir/bin"
  bash_path="$(command -v bash)"

  {
    printf '#!%s\n' "$bash_path"
    cat <<'EOF'
set -euo pipefail
printf '%s\n' "$*" > "$NIX_ARGS_OUT"
EOF
  } > "$workdir/bin/nix"
  chmod +x "$workdir/bin/nix"

  export PATH="$workdir/bin:$PATH"
  export NIX_ARGS_OUT="$workdir/nix.args"

  run run_nixos_rebuild_from_repo boot srvarr

  [ "$status" -eq 0 ]
  [ "$(<"$NIX_ARGS_OUT")" = "shell --inputs-from . nixpkgs#nh nixpkgs#nix-output-monitor -c nh os boot --hostname srvarr --print-build-logs --show-trace .#" ]
}

@test "run_nixos_rebuild_from_repo keeps dry-activate on nixos-rebuild" {
  workdir="$BATS_TMPDIR/nixos-dry-activate"
  mkdir -p "$workdir/bin"
  bash_path="$(command -v bash)"

  {
    printf '#!%s\n' "$bash_path"
    cat <<'EOF'
set -euo pipefail
printf '%s\n' "$*" > "$SUDO_ARGS_OUT"
"$@"
EOF
  } > "$workdir/bin/sudo"
  chmod +x "$workdir/bin/sudo"

  {
    printf '#!%s\n' "$bash_path"
    cat <<'EOF'
set -euo pipefail
printf '%s\n' "$*" > "$NIXOS_REBUILD_ARGS_OUT"
EOF
  } > "$workdir/bin/nixos-rebuild"
  chmod +x "$workdir/bin/nixos-rebuild"

  export PATH="$workdir/bin:$PATH"
  export SUDO_ARGS_OUT="$workdir/sudo.args"
  export NIXOS_REBUILD_ARGS_OUT="$workdir/nixos-rebuild.args"

  run run_nixos_rebuild_from_repo dry-activate srvarr

  [ "$status" -eq 0 ]
  [ "$(<"$SUDO_ARGS_OUT")" = "nixos-rebuild dry-activate --flake .#srvarr -L --show-trace" ]
  [ "$(<"$NIXOS_REBUILD_ARGS_OUT")" = "dry-activate --flake .#srvarr -L --show-trace" ]
}

@test "run_darwin_switch_from_repo activates through one sudo command" {
  workdir="$BATS_TMPDIR/darwin-single-sudo"
  rm -rf "$workdir"
  mkdir -p "$workdir/bin"
  mkdir -p "$workdir/system/sw/bin"
  bash_path="$(command -v bash)"

  {
    printf '#!%s\n' "$bash_path"
    cat <<'EOF'
set -euo pipefail
printf 'sudo\n' >> "$SUDO_CALLS_OUT"
printf '%s\n' "$*" >> "$SUDO_ARGS_OUT"
"$@"
EOF
  } > "$workdir/bin/sudo"
  chmod +x "$workdir/bin/sudo"

  {
    printf '#!%s\n' "$bash_path"
    cat <<'EOF'
set -euo pipefail
printf '%s\n' "$*" >> "$NIX_ARGS_OUT"
if [[ "${1-}" == "shell" ]]; then
  args=("$@")
  out_link=""
  for ((i = 0; i < ${#args[@]}; i++)); do
    if [[ "${args[$i]}" == "--out-link" ]]; then
      out_link="${args[$((i + 1))]}"
      break
    fi
  done
  if [[ -z "$out_link" ]]; then
    echo "missing --out-link" >&2
    exit 99
  fi
  ln -s "$SYSTEM_CONFIG_OUT" "$out_link"
fi
EOF
  } > "$workdir/bin/nix"
  chmod +x "$workdir/bin/nix"

  {
    printf '#!%s\n' "$bash_path"
    cat <<'EOF'
set -euo pipefail
printf '%s\n' "$*" > "$DARWIN_REBUILD_ARGS_OUT"
EOF
  } > "$workdir/system/sw/bin/darwin-rebuild"
  chmod +x "$workdir/system/sw/bin/darwin-rebuild"

  export PATH="$workdir/bin:$PATH"
  export SUDO_CALLS_OUT="$workdir/sudo.calls"
  export SUDO_ARGS_OUT="$workdir/sudo.args"
  export NIX_ARGS_OUT="$workdir/nix.args"
  export DARWIN_REBUILD_ARGS_OUT="$workdir/darwin-rebuild.args"
  export SYSTEM_CONFIG_OUT="$workdir/system"

  run run_darwin_switch_from_repo JGWXHWDL4X

  [ "$status" -eq 0 ]
  [ "$(wc -l < "$SUDO_CALLS_OUT" | tr -d ' ')" = "1" ]
  [[ "$(<"$SUDO_ARGS_OUT")" == *" -c "* ]]
  [ "$(wc -l < "$NIX_ARGS_OUT" | tr -d ' ')" = "2" ]
  [[ "$(<"$NIX_ARGS_OUT")" == *"shell --inputs-from . nixpkgs#nh nixpkgs#nix-output-monitor -c nh darwin build"* ]]
  [[ "$(<"$NIX_ARGS_OUT")" == *"--hostname JGWXHWDL4X"* ]]
  [[ "$(<"$NIX_ARGS_OUT")" == *"--diff auto .#"* ]]
  [[ "$(<"$NIX_ARGS_OUT")" == *"build --no-link --profile /nix/var/nix/profiles/system $workdir/system"* ]]
  [ "$(<"$DARWIN_REBUILD_ARGS_OUT")" = "activate" ]
}

@test "run_sudo_for_remote_darwin uses askpass sudo over ssh when configured" {
  workdir="$BATS_TMPDIR/darwin-ssh-sudo-askpass"
  rm -rf "$workdir"
  mkdir -p "$workdir/bin"
  touch "$workdir/sudo_ssh_password"
  local askpass_path
  bash_path="$(command -v bash)"

  {
    printf '#!%s\n' "$bash_path"
    cat <<'EOF'
set -euo pipefail
printf '%s\n' "$*" > "$SUDO_ARGS_OUT"
printf '%s\n' "${SUDO_ASKPASS:-}" > "$SUDO_ASKPASS_OUT"
exit "${SUDO_TEST_STATUS:-0}"
EOF
  } > "$workdir/bin/sudo"
  chmod +x "$workdir/bin/sudo"

  export PATH="$workdir/bin:$PATH"
  export SSH_CONNECTION="192.0.2.1 50000 192.0.2.2 22"
  export SUDO_ARGS_OUT="$workdir/sudo.args"
  export SUDO_ASKPASS_OUT="$workdir/sudo.askpass"
  export SUDO_SSH_PASSWORD_PAM_SERVICE_FILE="$workdir/sudo_ssh_password"
  export UPDATE_MACHINES_TEST_ASSUME_TTY=true

  run run_sudo_for_remote_darwin echo ok

  [ "$status" -eq 0 ]
  [ "$(<"$SUDO_ARGS_OUT")" = "-A echo ok" ]
  askpass_path="$(<"$SUDO_ASKPASS_OUT")"
  [ -n "$askpass_path" ]
  [ ! -e "$askpass_path" ]

  export SUDO_TEST_STATUS=42
  run run_sudo_for_remote_darwin echo failure
  [ "$status" -eq 42 ]
  askpass_path="$(<"$SUDO_ASKPASS_OUT")"
  [ ! -e "$askpass_path" ]
}

@test "update-machines resolves an explicit work host over mDNS" {
  workdir="$BATS_TMPDIR/update-machines-explicit-work-host"
  mkdir -p "$workdir/bin"
  write_update_machines_test_stubs "$workdir/bin"

  export PATH="$workdir/bin:$PATH"

  run bash ./apps/update-machines.sh --dry-run nv

  [ "$status" -eq 0 ]
  [[ "$output" == *"nv.local"* ]]
}

@test "update-machines reports all failed deploy hosts and exits nonzero" {
  workdir="$BATS_TMPDIR/update-machines-deploy-failure"
  mkdir -p "$workdir/bin"
  write_update_machines_test_stubs "$workdir/bin"
  local uploaded_script
  local expected_clone

  export PATH="$workdir/bin:$PATH"
  export SSH_TEST_MODE="deploy-fail"
  export SSH_UPLOADED_SCRIPT_OUT="$workdir/uploaded.sh"
  export NIX_BUILD_ARGS_OUT="$workdir/nix-build.args"
  export UPDATE_MACHINES_TEST_ASSUME_TTY=true

  run bash ./apps/update-machines.sh alpha beta

  [ "$status" -eq 1 ]
  [[ "$output" == *"Failed hosts: alpha, beta"* ]]
  [[ "$output" == *"Prebuilding 2 deployment target(s)"*"Checking SSH connectivity"* ]]
  [ "$(<"$NIX_BUILD_ARGS_OUT")" = "build -L --show-trace --no-link git+https://github.com/booxter/nix.git?ref=master#nixosConfigurations.alpha.config.system.build.toplevel git+https://github.com/booxter/nix.git?ref=master#nixosConfigurations.beta.config.system.build.toplevel" ]

  uploaded_script="$(<"$SSH_UPLOADED_SCRIPT_OUT")"
  expected_clone=$'GIT_CONFIG_NOSYSTEM=1 \\\n  GIT_CONFIG_GLOBAL=/dev/null \\\n  GIT_CONFIG_SYSTEM=/dev/null \\\n  GIT_TERMINAL_PROMPT=0 \\\n  git clone --branch "$branch" --single-branch "$https_url" "$repo_dir"'

  [[ "$uploaded_script" == *'target_config_name="$7"'* ]]
  [[ "$uploaded_script" == *'target_runtime_host="$8"'* ]]
  [[ "$uploaded_script" == *"$expected_clone"* ]]
  [[ "$uploaded_script" == *'SUDO_ASKPASS="$askpass_script" sudo -A "$@"'* ]]
  [[ "$uploaded_script" == *'run_sudo_for_remote_darwin "$bash_bin" -e -u -o pipefail -c'* ]]
  [[ "$uploaded_script" == *'run_nixos_rebuild_from_repo "$rebuild_action" "$target_config_name"'* ]]
}
