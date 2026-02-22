#!/usr/bin/env bats

@test "prox-deploy writes nixmoxer.conf and calls nixmoxer with flake target" {
  workdir="$BATS_TMPDIR/push-vm"
  mkdir -p "$workdir/bin"
  bash_path="$(command -v bash)"

  {
    printf '#!%s\n' "$bash_path"
    cat <<'EOF'
set -euo pipefail
printf '%s\n' "$*" > "$PASS_ARGS_OUT"
printf '%s\n' "secret-pass"
EOF
  } > "$workdir/bin/pass"
  chmod +x "$workdir/bin/pass"

  {
    printf '#!%s\n' "$bash_path"
    cat <<'EOF'
set -euo pipefail
printf '%s\n' "$*" > "$NIXMOXER_ARGS_OUT"
cat "nixmoxer.conf" > "$NIXMOXER_CONF_OUT"
EOF
  } > "$workdir/bin/nixmoxer"
  chmod +x "$workdir/bin/nixmoxer"

  export PATH="$workdir/bin:$PATH"
  export PASS_ARGS_OUT="$workdir/pass.args"
  export NIXMOXER_ARGS_OUT="$workdir/nixmoxer.args"
  export NIXMOXER_CONF_OUT="$workdir/nixmoxer.conf.snapshot"

  cd "$workdir"
  run bash "$BATS_TEST_DIRNAME/../scripts/prox-deploy.sh" prx1 root priv/lab-prx1 prox-srvarrvm

  [ "$status" -eq 0 ]
  [ "$(cat "$PASS_ARGS_OUT")" = "priv/lab-prx1" ]
  [ "$(cat "$NIXMOXER_ARGS_OUT")" = "--flake prox-srvarrvm" ]

  grep -q '^host=prx1:8006$' "$NIXMOXER_CONF_OUT"
  grep -q '^user=root@pam$' "$NIXMOXER_CONF_OUT"
  grep -q '^password=secret-pass$' "$NIXMOXER_CONF_OUT"
  grep -q '^verify_ssl=0$' "$NIXMOXER_CONF_OUT"

  [ ! -e "$workdir/nixmoxer.conf" ]
}

@test "prox-deploy validates argument count" {
  run bash "$BATS_TEST_DIRNAME/../scripts/prox-deploy.sh" only three args
  [ "$status" -ne 0 ]
  [[ "$output" == *"Usage: "* ]]
}

@test "prox-deploy removes config file when nixmoxer fails" {
  workdir="$BATS_TMPDIR/push-vm-fail"
  mkdir -p "$workdir/bin"
  bash_path="$(command -v bash)"

  {
    printf '#!%s\n' "$bash_path"
    cat <<'EOF'
set -euo pipefail
printf '%s\n' "secret-pass"
EOF
  } > "$workdir/bin/pass"
  chmod +x "$workdir/bin/pass"

  {
    printf '#!%s\n' "$bash_path"
    cat <<'EOF'
set -euo pipefail
[ -f "nixmoxer.conf" ]
exit 7
EOF
  } > "$workdir/bin/nixmoxer"
  chmod +x "$workdir/bin/nixmoxer"

  export PATH="$workdir/bin:$PATH"

  cd "$workdir"
  run bash "$BATS_TEST_DIRNAME/../scripts/prox-deploy.sh" prx1 root priv/lab-prx1 prox-srvarrvm

  [ "$status" -eq 7 ]
  [ ! -e "$workdir/nixmoxer.conf" ]
}
