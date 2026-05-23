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
if [[ "$*" == *".#nixosConfigurations.pi5.config.networking.interfaces.end0.ipv4.addresses"* ]]; then
  printf '%s\n' '[{"address":"127.0.0.1"}]'
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

@test "resolve_base_host maps pi5 to dhcp" {
  export HOST_BASE_MAP_JSON='{"pi5":"dhcp"}'
  run resolve_base_host pi5
  [ "$status" -eq 0 ]
  [ "$output" = "dhcp" ]
}

@test "resolve_base_host leaves other hosts unchanged" {
  export HOST_BASE_MAP_JSON='{"pi5":"dhcp"}'
  run resolve_base_host nvws
  [ "$status" -eq 0 ]
  [ "$output" = "nvws" ]
}

@test "hosts_from_work_map returns sorted unique hosts" {
  work_map='{"darwin":{"mmini":false},"nixos":{"nvws":true,"pi5":false}}'
  run hosts_from_work_map "$work_map"
  [ "$status" -eq 0 ]
  expected=$'mmini\nnvws\npi5'
  [ "$output" = "$expected" ]
}

@test "filter_hosts_by_mode includes only personal hosts" {
  work_map='{"darwin":{"mmini":false},"nixos":{"nvws":true,"pi5":false}}'
  run filter_hosts_by_mode personal "$work_map" nvws pi5 mmini
  [ "$status" -eq 0 ]
  expected=$'pi5\nmmini'
  [ "$output" = "$expected" ]
}

@test "filter_hosts_by_mode includes only work hosts" {
  work_map='{"darwin":{"mmini":false},"nixos":{"nvws":true,"pi5":false}}'
  run filter_hosts_by_mode work "$work_map" nvws pi5 mmini
  [ "$status" -eq 0 ]
  expected=$'nvws'
  [ "$output" = "$expected" ]
}

@test "filter_hosts_by_mode includes all hosts for both" {
  work_map='{"darwin":{"mmini":false},"nixos":{"nvws":true,"pi5":false}}'
  run filter_hosts_by_mode both "$work_map" nvws pi5 mmini
  [ "$status" -eq 0 ]
  expected=$'nvws\npi5\nmmini'
  [ "$output" = "$expected" ]
}

@test "prioritize_hosts orders priority, normal, deferred" {
  run prioritize_hosts prox-cachevm nvws zeta prx2-lab alpha
  [ "$status" -eq 0 ]
  expected=$'nvws\nprx2-lab\nzeta\nalpha\nprox-cachevm'
  [ "$output" = "$expected" ]
}

@test "format_host_list joins hosts with commas" {
  run format_host_list alpha beta gamma
  [ "$status" -eq 0 ]
  [ "$output" = "alpha, beta, gamma" ]
}

@test "run_nixos_rebuild_from_repo uses requested rebuild action" {
  workdir="$BATS_TMPDIR/nixos-rebuild-action"
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

  run run_nixos_rebuild_from_repo boot prox-srvarrvm

  [ "$status" -eq 0 ]
  [ "$(<"$SUDO_ARGS_OUT")" = "nixos-rebuild boot --flake .#prox-srvarrvm -L --show-trace" ]
  [ "$(<"$NIXOS_REBUILD_ARGS_OUT")" = "boot --flake .#prox-srvarrvm -L --show-trace" ]
}

@test "run_darwin_switch_from_repo uses installed darwin-rebuild" {
  workdir="$BATS_TMPDIR/darwin-rebuild-in-path"
  mkdir -p "$workdir/bin"
  bash_path="$(command -v bash)"

  {
    printf '#!%s\n' "$bash_path"
    cat <<'EOF'
set -euo pipefail
printf '%s\n' "$*" > "$SUDO_ARGS_OUT"
if [[ "$1" = "-H" ]]; then
  shift
fi
"$@"
EOF
  } > "$workdir/bin/sudo"
  chmod +x "$workdir/bin/sudo"

  {
    printf '#!%s\n' "$bash_path"
    cat <<'EOF'
set -euo pipefail
printf '%s\n' "$*" > "$DARWIN_REBUILD_ARGS_OUT"
EOF
  } > "$workdir/bin/darwin-rebuild"
  chmod +x "$workdir/bin/darwin-rebuild"

  {
    printf '#!%s\n' "$bash_path"
    cat <<'EOF'
set -euo pipefail
echo "unexpected nix invocation" >&2
exit 99
EOF
  } > "$workdir/bin/nix"
  chmod +x "$workdir/bin/nix"

  export PATH="$workdir/bin:$PATH"
  export SUDO_ARGS_OUT="$workdir/sudo.args"
  export DARWIN_REBUILD_ARGS_OUT="$workdir/darwin-rebuild.args"

  run run_darwin_switch_from_repo JGWXHWDL4X

  [ "$status" -eq 0 ]
  [ "$(<"$SUDO_ARGS_OUT")" = "-H $workdir/bin/darwin-rebuild switch --flake .#JGWXHWDL4X -L --show-trace" ]
  [ "$(<"$DARWIN_REBUILD_ARGS_OUT")" = "switch --flake .#JGWXHWDL4X -L --show-trace" ]
}

@test "run_darwin_switch_from_repo falls back to repo-pinned darwin-rebuild build" {
  workdir="$BATS_TMPDIR/darwin-rebuild-build"
  mkdir -p "$workdir/bin" "$workdir/system/sw/bin"
  bash_path="$(command -v bash)"

  {
    printf '#!%s\n' "$bash_path"
    cat <<'EOF'
set -euo pipefail
printf '%s\n' "$*" > "$SUDO_ARGS_OUT"
if [[ "$1" = "-H" ]]; then
  shift
fi
"$@"
EOF
  } > "$workdir/bin/sudo"
  chmod +x "$workdir/bin/sudo"

  {
    printf '#!%s\n' "$bash_path"
    cat <<'EOF'
set -euo pipefail
printf '%s\n' "$*" > "$NIX_ARGS_OUT"
printf '%s\n' "$DARWIN_SYSTEM_OUT"
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

  export PATH="$workdir/bin"
  export SUDO_ARGS_OUT="$workdir/sudo.args"
  export NIX_ARGS_OUT="$workdir/nix.args"
  export DARWIN_REBUILD_ARGS_OUT="$workdir/darwin-rebuild.args"
  export DARWIN_SYSTEM_OUT="$workdir/system"

  run run_darwin_switch_from_repo JGWXHWDL4X

  [ "$status" -eq 0 ]
  [ "$(<"$NIX_ARGS_OUT")" = "build --no-link --print-out-paths .#darwinConfigurations.JGWXHWDL4X.system -L --show-trace" ]
  [ "$(<"$SUDO_ARGS_OUT")" = "-H $workdir/system/sw/bin/darwin-rebuild switch --flake .#JGWXHWDL4X -L --show-trace" ]
  [ "$(<"$DARWIN_REBUILD_ARGS_OUT")" = "switch --flake .#JGWXHWDL4X -L --show-trace" ]
}

@test "update-machines reports all failed deploy hosts and exits nonzero" {
  workdir="$BATS_TMPDIR/update-machines-deploy-failure"
  mkdir -p "$workdir/bin"
  write_update_machines_test_stubs "$workdir/bin"

  export PATH="$workdir/bin:$PATH"
  export SSH_TEST_MODE="deploy-fail"

  run script -q /dev/null bash ./scripts/update-machines.sh alpha beta

  [ "$status" -eq 1 ]
  [[ "$output" == *"Failed hosts: alpha, beta"* ]]
}
