#!/usr/bin/env bats

setup() {
  source ./scripts/_helpers/update-machines-lib.sh
}

write_update_machines_test_stubs() {
  local stub_dir="$1"
  local bash_path
  bash_path="$(command -v bash)"

  {
    printf '#!%s\n' "$bash_path"
    cat <<'EOF'
set -euo pipefail
if [[ "$*" == *"hostInventory.site.lan.gateway.address"* ]]; then
  printf '%s\n' '127.0.0.1'
elif [[ "$*" == *"hostInventory = import ./lib/inventory.nix"* ]]; then
  printf '%s\n' '{"alpha":"alpha","beta":"beta","gamma":"gamma"}'
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

  {
    printf '#!%s\n' "$bash_path"
    cat <<'EOF'
set -euo pipefail
if [[ "${1-}" == "-q" ]]; then
  shift
fi
if [[ $# -lt 2 ]]; then
  echo "script stub: expected output file and command" >&2
  exit 64
fi
shift
python3 - "$@" <<'PY'
import os
import pty
import subprocess
import sys

cmd = sys.argv[1:]
if not cmd:
    sys.exit(64)

master_fd, slave_fd = pty.openpty()
proc = subprocess.Popen(cmd, stdin=slave_fd, stdout=slave_fd, stderr=slave_fd, close_fds=True)
os.close(slave_fd)

try:
    while True:
        chunk = os.read(master_fd, 4096)
        if not chunk:
            break
        os.write(sys.stdout.fileno(), chunk)
except OSError:
    pass
finally:
    os.close(master_fd)

proc.wait()
sys.exit(proc.returncode)
PY
EOF
  } > "$stub_dir/script"
  chmod +x "$stub_dir/script"
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
  work_map='{"darwin":{"mmini":false},"nixos":{"beast":false,"nvws":true}}'
  run filter_hosts_by_mode both "$work_map" nvws beast mmini
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

@test "run_darwin_switch_from_repo uses pinned nh" {
  workdir="$BATS_TMPDIR/darwin-nh"
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

  run run_darwin_switch_from_repo JGWXHWDL4X

  [ "$status" -eq 0 ]
  [ "$(<"$NIX_ARGS_OUT")" = "shell --inputs-from . nixpkgs#nh nixpkgs#nix-output-monitor -c nh darwin switch --hostname JGWXHWDL4X --print-build-logs --show-trace .#" ]
}

@test "update-machines reports all failed deploy hosts and exits nonzero" {
  workdir="$BATS_TMPDIR/update-machines-deploy-failure"
  mkdir -p "$workdir/bin"
  write_update_machines_test_stubs "$workdir/bin"

  export PATH="$workdir/bin:$PATH"
  export SSH_TEST_MODE="deploy-fail"
  export SSH_UPLOADED_SCRIPT_OUT="$workdir/uploaded.sh"

  run script -q /dev/null bash ./scripts/update-machines.sh alpha beta

  [ "$status" -eq 1 ]
  [[ "$output" == *"Failed hosts: alpha, beta"* ]]
  grep -Fq 'target_config_name="$7"' "$SSH_UPLOADED_SCRIPT_OUT"
  grep -Fq 'target_runtime_host="$8"' "$SSH_UPLOADED_SCRIPT_OUT"
  grep -Fq 'run_nixos_rebuild_from_repo "$rebuild_action" "$target_config_name"' "$SSH_UPLOADED_SCRIPT_OUT"
}
