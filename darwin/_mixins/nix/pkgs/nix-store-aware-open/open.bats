setup() {
  export TMPDIR="$BATS_TEST_TMPDIR/tmp"
  export OPEN_CAPTURE="$BATS_TEST_TMPDIR/open-args"
  mkdir -p "$TMPDIR"

  ordinary_app="$BATS_TEST_TMPDIR/Ordinary App.app"
  mkdir -p "$ordinary_app"

  result="$BATS_TEST_TMPDIR/result"
  ln -s "${TEST_STORE_APP%/Applications/*}" "$result"
  result_app="$result/Applications/Test App.app"
}

captured_arg() {
  sed -n "$1"p "$OPEN_CAPTURE"
}

@test "passes an ordinary app through unchanged" {
  "$OPEN_UNDER_TEST" "$ordinary_app"

  [ "$(captured_arg 1)" = "$ordinary_app" ]
  [ ! -e "$TMPDIR/nix-open-apps" ]
}

@test "copies a directly referenced Nix store app" {
  "$OPEN_UNDER_TEST" "$TEST_STORE_APP"

  copied_app=$(captured_arg 1)
  [[ $copied_app = "$TMPDIR/nix-open-apps/"*"/Applications/Test App.app" ]]
  [ -f "$copied_app/Contents/fixture" ]
  [ ! -L "$copied_app" ]
}

@test "resolves a result symlink before deciding to copy" {
  "$OPEN_UNDER_TEST" "$result_app/"

  copied_app=$(captured_arg 1)
  [[ $copied_app = "$TMPDIR/nix-open-apps/"*"/Applications/Test App.app" ]]
  [ "$copied_app" != "$result_app" ]
}

@test "reuses the content-addressed copy" {
  "$OPEN_UNDER_TEST" "$result_app"
  copied_app=$(captured_arg 1)
  touch "$copied_app/reused"

  "$OPEN_UNDER_TEST" "$result_app"

  [ "$(captured_arg 1)" = "$copied_app" ]
  [ -e "$copied_app/reused" ]
}

@test "copies a store app passed to -a and preserves documents" {
  document="$BATS_TEST_TMPDIR/document"
  touch "$document"

  "$OPEN_UNDER_TEST" -n -a "$result_app" "$document"

  [ "$(captured_arg 1)" = -n ]
  [ "$(captured_arg 2)" = -a ]
  [[ $(captured_arg 3) = "$TMPDIR/nix-open-apps/"*"/Applications/Test App.app" ]]
  [ "$(captured_arg 4)" = "$document" ]
}

@test "does not rewrite reveal targets" {
  "$OPEN_UNDER_TEST" -R "$result_app"

  [ "$(captured_arg 1)" = -R ]
  [ "$(captured_arg 2)" = "$result_app" ]
  [ ! -e "$TMPDIR/nix-open-apps" ]
}

@test "does not interpret application arguments as paths to open" {
  "$OPEN_UNDER_TEST" "$result_app" --args "$TEST_STORE_APP"

  [[ $(captured_arg 1) = "$TMPDIR/nix-open-apps/"*"/Applications/Test App.app" ]]
  [ "$(captured_arg 2)" = --args ]
  [ "$(captured_arg 3)" = "$TEST_STORE_APP" ]
}
