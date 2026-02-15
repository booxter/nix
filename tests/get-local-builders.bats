#!/usr/bin/env bats

setup() {
  tmpdir="$(mktemp -d)"
}

teardown() {
  rm -rf "$tmpdir"
}

@test "reads builders from nix.conf (no indent)" {
  cat >"$tmpdir/nix.conf" <<'EOF'
builders = builder1;builder2
EOF

  run env NIX_CONF="$tmpdir/nix.conf" NIX_MACHINES="$tmpdir/machines" bash ./scripts/get-local-builders.sh
  [ "$status" -eq 0 ]
  [ "$output" = "builder1;builder2" ]
}

@test "reads builders from nix.conf with leading whitespace" {
  cat >"$tmpdir/nix.conf" <<'EOF'
  builders = builderA;builderB
EOF

  run env NIX_CONF="$tmpdir/nix.conf" NIX_MACHINES="$tmpdir/machines" bash ./scripts/get-local-builders.sh
  [ "$status" -eq 0 ]
  [ "$output" = "builderA;builderB" ]
}

@test "uses last builders line in nix.conf" {
  cat >"$tmpdir/nix.conf" <<'EOF'
builders = old
  builders = new1;new2
EOF

  run env NIX_CONF="$tmpdir/nix.conf" NIX_MACHINES="$tmpdir/machines" bash ./scripts/get-local-builders.sh
  [ "$status" -eq 0 ]
  [ "$output" = "new1;new2" ]
}

@test "falls back to nix.machines when nix.conf has no builders" {
  cat >"$tmpdir/nix.conf" <<'EOF'
trusted-users = root
EOF
  cat >"$tmpdir/machines" <<'EOF'
# comment
builder1 x86_64-linux /etc/nix/id 4 1
builder2 aarch64-linux /etc/nix/id 2 1

EOF

  run env NIX_CONF="$tmpdir/nix.conf" NIX_MACHINES="$tmpdir/machines" bash ./scripts/get-local-builders.sh
  [ "$status" -eq 0 ]
  [ "$output" = "builder1 x86_64-linux /etc/nix/id 4 1;builder2 aarch64-linux /etc/nix/id 2 1" ]
}

@test "local-only filters to localhost and linux-builder" {
  cat >"$tmpdir/nix.conf" <<'EOF'
builders = remote1;localhost;linux-builder;remote2
EOF

  run env NIX_CONF="$tmpdir/nix.conf" NIX_MACHINES="$tmpdir/machines" bash ./scripts/get-local-builders.sh --local
  [ "$status" -eq 0 ]
  [ "$output" = "localhost;linux-builder" ]
}
