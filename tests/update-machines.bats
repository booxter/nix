#!/usr/bin/env bats

setup() {
  source ./scripts/_helpers/update-machines-lib.sh
}

@test "calc_min_disk_kb_from_gib converts GiB to KiB" {
  run calc_min_disk_kb_from_gib 20
  [ "$status" -eq 0 ]
  [ "$output" = "20971520" ]
}

@test "resolve_base_host maps pi5 to dhcp" {
  run resolve_base_host pi5
  [ "$status" -eq 0 ]
  [ "$output" = "dhcp" ]
}

@test "resolve_base_host leaves other hosts unchanged" {
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
