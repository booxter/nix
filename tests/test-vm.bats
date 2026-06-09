#!/usr/bin/env bats

setup() {
  workdir="$BATS_TMPDIR/vm-app"
  mkdir -p "$workdir/bin"
  bash_path="$(command -v bash)"

  {
    printf '#!%s\n' "$bash_path"
    cat <<'EOF'
set -euo pipefail

if [[ "${1:-}" == "eval" && "${2:-}" == "--impure" && "${3:-}" == "--json" && "${4:-}" == "--expr" ]]; then
  if [[ -n "${NIX_EVAL_STDERR:-}" ]]; then
    printf '%s\n' "${NIX_EVAL_STDERR}" >&2
  fi
  if [[ -n "${NIX_EVAL_EXIT_CODE:-}" ]]; then
    exit "${NIX_EVAL_EXIT_CODE}"
  fi
  printf '%s\n' "${FLAKE_JSON:?}"
  exit 0
fi

if [[ "${1:-}" == "run" ]]; then
  {
    printf 'VM_TARGET_CONFIG=%s\n' "${VM_TARGET_CONFIG:-}"
    printf 'VM_GUI=%s\n' "${VM_GUI:-}"
    printf '%s\n' "$*"
  } > "${NIX_RUN_ARGS_OUT:?}"
  exit "${NIX_RUN_EXIT_CODE:-0}"
fi

echo "unexpected nix args: $*" >&2
exit 99
EOF
  } > "$workdir/bin/nix"
  chmod +x "$workdir/bin/nix"

  export PATH="$workdir/bin:$PATH"
  export NIX_RUN_ARGS_OUT="$workdir/nix-run.args"
}

@test "vm --help lists available target hosts" {
  export FLAKE_JSON='{
    "nixosConfigurations":{"builder1":{},"srvarr":{},"beast":{},"prx1-lab":{}},
    "targetAliases":{"builder1":"builder1","srvarr":"srvarr","beast":"beast","prx1-lab":"prx1-lab"},
    "targetDisplayNames":["builder1","srvarr","beast","prx1-lab"]
  }'

  run bash ./scripts/vm.sh --help

  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: vm [--gui] <target-host>"* ]]
  [[ "$output" == *"Available target hosts"* ]]
  grep -Fqx "  builder1" <<<"$output"
  grep -Fqx "  srvarr" <<<"$output"
  grep -Fqx "  beast" <<<"$output"
  grep -Fqx "  prx1-lab" <<<"$output"
}

@test "vm --help exits non-zero when flake evaluation fails" {
  export NIX_EVAL_EXIT_CODE=1
  export NIX_EVAL_STDERR='boom'

  run bash ./scripts/vm.sh --help

  [ "$status" -ne 0 ]
  [[ "$output" == *"Failed to evaluate flake for VM target discovery"* ]]
}

@test "vm --gui enables graphics for the resolved vm" {
  export FLAKE_JSON='{
    "nixosConfigurations":{"builder1":{},"beast":{}},
    "targetAliases":{"builder1":"builder1"}
  }'

  run bash ./scripts/vm.sh --gui builder1

  [ "$status" -eq 0 ]
  grep -Fq "VM_TARGET_CONFIG=builder1" "$NIX_RUN_ARGS_OUT"
  grep -Fq "VM_GUI=1" "$NIX_RUN_ARGS_OUT"
  grep -Fq -- "--expr" "$NIX_RUN_ARGS_OUT"
  grep -Fq "getAttr targetConfig f.nixosConfigurations" "$NIX_RUN_ARGS_OUT"
  grep -Fq "virtualisation.vmVariant.virtualisation.host.pkgs = lib.mkForce hostPkgs;" "$NIX_RUN_ARGS_OUT"
  grep -Fq "graphics = lib.mkForce true;" "$NIX_RUN_ARGS_OUT"
}

@test "vm resolves short VM name to config" {
  export FLAKE_JSON='{
    "nixosConfigurations":{"builder1":{},"beast":{}},
    "targetAliases":{"builder1":"builder1","beast":"beast"},
    "targetDisplayNames":["builder1","beast"]
  }'

  run bash ./scripts/vm.sh builder1

  [ "$status" -eq 0 ]
  grep -Fq "VM_TARGET_CONFIG=builder1" "$NIX_RUN_ARGS_OUT"
  grep -Fq "VM_GUI=0" "$NIX_RUN_ARGS_OUT"
  grep -Fq "cfg.config.system.build.vm" "$NIX_RUN_ARGS_OUT"
}

@test "vm resolves real host directly" {
  export FLAKE_JSON='{"nixosConfigurations":{"beast":{}}}'

  run bash ./scripts/vm.sh beast

  [ "$status" -eq 0 ]
  grep -Fq "VM_TARGET_CONFIG=beast" "$NIX_RUN_ARGS_OUT"
}

@test "vm reports unknown target host" {
  export FLAKE_JSON='{"nixosConfigurations":{"beast":{}}}'

  run bash ./scripts/vm.sh does-not-exist

  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown target host: does-not-exist"* ]]
  [[ "$output" == *"Usage: vm [--gui] <target-host>"* ]]
}
