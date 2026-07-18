#!/usr/bin/env bats

setup() {
  tmpdir="$(mktemp -d)"
  mkdir -p "$tmpdir/bin"
  helper="$PWD/home-manager/_mixins/scm/pkgs/git-send-email-store-password.sh"
  bash_path="$(command -v bash)"

  printf '#!%s\n' "$bash_path" >"$tmpdir/bin/git"
  cat >>"$tmpdir/bin/git" <<'EOF'
set -euo pipefail

if [[ "${1:-}" == "config" && "${2:-}" == "--get" ]]; then
  case "${3:-}" in
    sendemail.smtpserver)
      printf '%s\n' "${TEST_SMTP_SERVER:-smtp.example.com}"
      ;;
    sendemail.smtpserverport)
      if [[ -n "${TEST_SMTP_PORT-587}" ]]; then
        printf '%s\n' "${TEST_SMTP_PORT-587}"
      else
        exit 1
      fi
      ;;
    sendemail.smtpuser)
      printf '%s\n' "${TEST_SMTP_USER:-user@example.com}"
      ;;
    *)
      exit 1
      ;;
  esac
  exit 0
fi

printf '%s\n' "$@" >"$TEST_GIT_ARGS"
cat >"$TEST_GIT_STDIN"
EOF
  chmod +x "$tmpdir/bin/git"

  export TEST_GIT_ARGS="$tmpdir/git.args"
  export TEST_GIT_STDIN="$tmpdir/git.stdin"
}

teardown() {
  rm -rf "$tmpdir"
}

@test "describes its stdin and Git configuration interface" {
  run bash "$helper" --help

  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: git-send-email-store-password"* ]]
  [[ "$output" == *"Read an SMTP password from stdin"* ]]
  [[ "$output" == *"sendemail.smtpServerPort"* ]]
}

@test "stores the configured SMTP credential through osxkeychain" {
  printf '%s\n' "app-password" >"$tmpdir/password"

  run env PATH="$tmpdir/bin:$PATH" bash "$helper" <"$tmpdir/password"

  [ "$status" -eq 0 ]
  [ "$output" = \
    "Stored the SMTP credential for user@example.com at smtp.example.com:587 in Keychain." ]
  [ "$(cat "$TEST_GIT_ARGS")" = $'-c\ncredential.helper=\n-c\ncredential.helper=osxkeychain\ncredential\napprove' ]
  [ "$(cat "$TEST_GIT_STDIN")" = $'protocol=smtp\nhost=smtp.example.com:587\nusername=user@example.com\npassword=app-password' ]
  [[ "$output" != *"app-password"* ]]
}

@test "supports an SMTP server without an explicit port" {
  printf '%s\n' "app-password" >"$tmpdir/password"

  run env \
    PATH="$tmpdir/bin:$PATH" \
    TEST_SMTP_PORT= \
    bash "$helper" <"$tmpdir/password"

  [ "$status" -eq 0 ]
  grep -Fx "host=smtp.example.com" "$TEST_GIT_STDIN"
}

@test "rejects an empty password" {
  : >"$tmpdir/password"

  run env PATH="$tmpdir/bin:$PATH" bash "$helper" <"$tmpdir/password"

  [ "$status" -eq 1 ]
  [ "$output" = "Refusing to store an empty SMTP password." ]
  [ ! -e "$TEST_GIT_ARGS" ]
}

@test "rejects a multiline password" {
  printf 'first\nsecond\n' >"$tmpdir/password"

  run env PATH="$tmpdir/bin:$PATH" bash "$helper" <"$tmpdir/password"

  [ "$status" -eq 1 ]
  [ "$output" = "The SMTP password must be a single line." ]
  [ ! -e "$TEST_GIT_ARGS" ]
}
