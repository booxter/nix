{ pkgs, ... }:
let
  inherit (pkgs) lib;
  indicator = pkgs.writeShellScriptBin "test-indicator" ''
    set -e
    touch "$activity/active"
    ${lib.getExe' pkgs.coreutils "cat"} >/dev/null
    rm "$activity/active"
    touch "$activity/finished"
  '';
  gnupg = pkgs.writeShellScriptBin "gpg" ''
    output=-
    while [[ $# -gt 0 ]]; do
      if [[ "$1" == -o ]]; then
        output="$2"
        shift 2
      else
        shift
      fi
    done
    if [[ "$output" == - ]]; then
      printf 'sample password\n'
    else
      printf 'sample password\n' > "$output"
    fi
  '';
  editor = pkgs.writeShellScript "test-editor" ''
    set -e
    test ! -e "$activity/active"
    test -e "$activity/finished"
    test "$(cat "$1")" = 'sample password'
    touch "$activity/editor-ran"
  '';
  conflictingGpg = pkgs.writeShellScriptBin "gpg2" ''
    echo 'pass bypassed its activity wrapper' >&2
    exit 97
  '';
  pass = pkgs.callPackage ../../hm/_mixins/security/pass/with-indicator.nix {
    inherit indicator gnupg;
  };
in
pkgs.runCommand "pass-indicator" { nativeBuildInputs = [ conflictingGpg ]; } ''
  export HOME="$TMPDIR/home"
  export PASSWORD_STORE_DIR="$TMPDIR/store"
  export activity="$TMPDIR/activity"
  export EDITOR=${editor}
  # This fixture contains dummy plaintext only. Avoid pass's privileged macOS
  # RAM-disk setup inside the build sandbox.
  export SECURE_TMPDIR="$TMPDIR/editor"
  mkdir -p "$HOME" "$PASSWORD_STORE_DIR" "$activity" "$SECURE_TMPDIR"
  printf 'dummy ciphertext\n' > "$PASSWORD_STORE_DIR/example.gpg"
  printf 'dummy recipient\n' > "$PASSWORD_STORE_DIR/.gpg-id"

  test "$(${lib.getExe pass} show example)" = 'sample password'
  test ! -e "$activity/active"
  test -e "$activity/finished"

  rm "$activity/finished"
  if ${lib.getExe pass} edit example > "$activity/edit.log" 2>&1; then
    echo 'An unchanged password should make pass edit exit unsuccessfully' >&2
    exit 1
  fi
  if [[ ! -e "$activity/editor-ran" ]] || ! grep -q '^Password unchanged\.$' "$activity/edit.log"; then
    cat "$activity/edit.log" >&2
    exit 1
  fi

  rm "$activity/finished"
  ${lib.getExe pass} ls
  test ! -e "$activity/active"
  test ! -e "$activity/finished"
  touch "$out"
''
