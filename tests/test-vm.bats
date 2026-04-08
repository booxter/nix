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
  printf '%s\n' "${FLAKE_JSON:?}"
  exit 0
fi

if [[ "${1:-}" == "run" ]]; then
  printf '%s\n' "$*" > "${NIX_RUN_ARGS_OUT:?}"
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

@test "vm --help lists local-vm targets and regular hosts" {
  export FLAKE_JSON='{"nixosConfigurations":{"local-builder1vm":{},"local-srvarrvm":{},"local-beastvm":{},"local-prx1-labvm":{},"prox-srvarrvm":{},"beast":{},"prx1-lab":{}}}'

  run bash ./scripts/vm.sh --help

  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: vm [--gui] <target-host>"* ]]
  [[ "$output" == *"Available target hosts"* ]]
  grep -Fqx "  builder1" <<<"$output"
  grep -Fqx "  srvarr" <<<"$output"
  grep -Fqx "  beast" <<<"$output"
  grep -Fqx "  prx1-lab" <<<"$output"
  ! grep -Fqx "  prox-srvarrvm" <<<"$output"
}

@test "vm --gui enables graphics for the resolved local vm" {
  export FLAKE_JSON='{"nixosConfigurations":{"local-builder1vm":{},"builder1":{},"beast":{}}}'

  run bash ./scripts/vm.sh --gui builder1

  [ "$status" -eq 0 ]
  grep -Fq -- "--expr" "$NIX_RUN_ARGS_OUT"
  grep -Fq "getAttr targetConfig f.nixosConfigurations" "$NIX_RUN_ARGS_OUT"
  grep -Fq "graphics = lib.mkForce true;" "$NIX_RUN_ARGS_OUT"
}

@test "vm resolves host via local-<host>vm" {
  export FLAKE_JSON='{"nixosConfigurations":{"local-builder1vm":{},"builder1":{},"beast":{}}}'

  run bash ./scripts/vm.sh builder1

  [ "$status" -eq 0 ]
  grep -Fq "#nixosConfigurations.local-builder1vm.config.system.build.vm" "$NIX_RUN_ARGS_OUT"
}

@test "vm resolves beast via local-beastvm" {
  export FLAKE_JSON='{"nixosConfigurations":{"local-beastvm":{},"beast":{},"prox-srvarrvm":{}}}'

  run bash ./scripts/vm.sh beast

  [ "$status" -eq 0 ]
  grep -Fq "#nixosConfigurations.local-beastvm.config.system.build.vm" "$NIX_RUN_ARGS_OUT"
}

@test "vm rejects host without local-<host>vm target" {
  export FLAKE_JSON='{"nixosConfigurations":{"beast":{},"prx1-lab":{},"prox-srvarrvm":{}}}'

  run bash ./scripts/vm.sh beast

  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown target host: beast"* ]]
}

@test "vm reports unknown target host" {
  export FLAKE_JSON='{"nixosConfigurations":{"beast":{}}}'

  run bash ./scripts/vm.sh does-not-exist

  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown target host: does-not-exist"* ]]
  [[ "$output" == *"Usage: vm [--gui] <target-host>"* ]]
}
