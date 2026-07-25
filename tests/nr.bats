#!/usr/bin/env bats

setup() {
  export NR="$BATS_TEST_DIRNAME/../home-manager/_mixins/cli/pkgs/nr/nr"

  function nixpkgs-review() {
    printf '%s\n' "$@"
  }
  export -f nixpkgs-review
}

@test "defaults to two systems without an aarch64-linux builder" {
  export NR_BUILDERS="ssh-ng://builder x86_64-linux - 4 100 - - -"

  run bash "$NR" 123

  [ "$status" -eq 0 ]
  [ "${lines[3]}" = "--systems=x86_64-linux aarch64-darwin" ]
}

@test "includes aarch64-linux when a builder supports it" {
  export NR_BUILDERS="ssh://builder x86_64-linux,aarch64-linux - 4 100 - - -"

  run bash "$NR" 123

  [ "$status" -eq 0 ]
  [ "${lines[3]}" = "--systems=x86_64-linux aarch64-linux aarch64-darwin" ]
}

@test "explicit systems override the builder-derived default" {
  export NR_BUILDERS="ssh://builder aarch64-linux - 4 100 - - -"

  run bash "$NR" -s x86_64-linux 123

  [ "$status" -eq 0 ]
  [ "${lines[3]}" = "--systems=x86_64-linux" ]
}
