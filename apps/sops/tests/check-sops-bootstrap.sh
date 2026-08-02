#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../../.." && pwd)"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local message="${3:-}"
  if [[ "$expected" != "$actual" ]]; then
    fail "${message:-expected \"$expected\" but got \"$actual\"}"
  fi
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local message="${3:-}"
  if [[ "$haystack" != *"$needle"* ]]; then
    fail "${message:-expected output to contain \"$needle\"}"
  fi
}

run_and_capture() {
  local out_file="$1"
  shift
  if ! "$@" >"$out_file" 2>&1; then
    cat "$out_file" >&2
    fail "command failed: $*"
  fi
}

run_expect_failure() {
  local out_file="$1"
  shift
  if "$@" >"$out_file" 2>&1; then
    cat "$out_file" >&2
    fail "expected command to fail: $*"
  fi
}

main() {
  local repo="$WORKDIR/repo"
  local fake_bin="$WORKDIR/fake-bin"
  local out="$WORKDIR/out.txt"
  local ssh_log="$WORKDIR/ssh.log"
  local operator_key="$WORKDIR/operator-age.txt"
  local runtime_key="$WORKDIR/runtime-age.txt"
  local operator_pubkey
  local runtime_pubkey
  local bash_path

  mkdir -p \
    "$repo/apps/_helpers" \
    "$repo/apps/sops" \
    "$repo/secrets/main" \
    "$fake_bin"
  cp "$REPO_ROOT/apps/_helpers/secret-domains.sh" "$repo/apps/_helpers/"
  cp "$REPO_ROOT/apps/sops/age-recipient.sh" "$repo/apps/sops/"
  cp "$REPO_ROOT/apps/sops/sops-bootstrap.sh" "$repo/apps/sops/"
  chmod +x "$repo/apps/sops/age-recipient.sh"

  git -C "$repo" init -q
  age-keygen -o "$operator_key" >/dev/null 2>&1
  operator_pubkey="$(age-keygen -y "$operator_key")"
  bash_path="$(command -v bash)"

  cat > "$repo/secret-domains.json" <<'EOF'
{"controller":"main","newhost":"main","secondhost":"main"}
EOF
  cat > "$repo/secrets/main/_template.yaml" <<'EOF'
bootstrap:
  token: "REPLACE_ME"
EOF
  {
    printf '#!%s\n' "$bash_path"
    cat <<'EOF'
set -euo pipefail

printf '%s\n' "$*" >> "$SSH_TEST_LOG"
exit 99
EOF
  } > "$fake_bin/ssh"
  {
    printf '#!%s\n' "$bash_path"
    cat <<'EOF'
set -euo pipefail
exec bash "$SOPS_TEST_RECIPIENT_SCRIPT" "$@"
EOF
  } > "$fake_bin/age-recipient"
  {
    printf '#!%s\n' "$bash_path"
    cat <<'EOF'
set -euo pipefail

if [[ "${1:-}" != "-u" ]]; then
  printf 'unexpected id invocation: %s\n' "$*" >&2
  exit 2
fi
printf '%s\n' 1000
EOF
  } > "$fake_bin/id"
  {
    printf '#!%s\n' "$bash_path"
    cat <<'EOF'
set -euo pipefail

mapped=()
for arg in "$@"; do
  case "$arg" in
    /var/lib/sops-nix)
      mapped+=("$(dirname -- "$SUDO_TEST_RUNTIME_KEY")")
      ;;
    /var/lib/sops-nix/key.txt)
      mapped+=("$SUDO_TEST_RUNTIME_KEY")
      ;;
    *)
      mapped+=("$arg")
      ;;
  esac
done
exec "${mapped[@]}"
EOF
  } > "$fake_bin/sudo"
  chmod +x \
    "$fake_bin/age-recipient" \
    "$fake_bin/id" \
    "$fake_bin/ssh" \
    "$fake_bin/sudo"

  local -a bootstrap_env=(
    env
    "PATH=$fake_bin:$PATH"
    "SOPS_AGE_KEY_FILE=$operator_key"
    "SOPS_AGE_RECIPIENT_HELPER=$fake_bin/age-recipient"
    "SOPS_MACHINE_HOSTNAME=controller"
    "SOPS_SECRET_DOMAINS_FILE=$repo/secret-domains.json"
    "SOPS_TEST_RECIPIENT_SCRIPT=$repo/apps/sops/age-recipient.sh"
    "SSH_TEST_LOG=$ssh_log"
    "SUDO_TEST_RUNTIME_KEY=$runtime_key"
  )
  local bootstrap="$repo/apps/sops/sops-bootstrap.sh"

  cd "$repo"

  printf '==> reject remote bootstrap without a terminal\n'
  run_expect_failure "$out" "${bootstrap_env[@]}" bash "$bootstrap" newhost
  assert_contains "$(cat "$out")" "no TTY available"
  [[ ! -e "$ssh_log" ]] || fail "TTY rejection should happen before SSH"

  printf '==> reject a host assigned to another secret domain\n'
  run_expect_failure "$out" "${bootstrap_env[@]}" \
    bash "$bootstrap" --domain work newhost
  assert_contains "$(cat "$out")" \
    "Host newhost belongs to secret domain 'main', not 'work'."

  printf '==> bootstrap a local host and create its encryption policy\n'
  run_and_capture "$out" "${bootstrap_env[@]}" \
    bash "$bootstrap" --local newhost
  assert_contains "$(cat "$out")" "Created .sops.yaml."
  assert_contains "$(cat "$out")" "Created encrypted secrets/main/newhost.yaml."
  [[ -s "$runtime_key" ]] || fail "bootstrap should create the runtime age key"
  runtime_pubkey="$(age-keygen -y "$runtime_key")"

  assert_eq "secrets/main/newhost\\.yaml$" \
    "$(yq -r '.creation_rules[0].path_regex' .sops.yaml)" \
    "bootstrap should create a host-specific SOPS rule"
  assert_eq "2" "$(yq -o=json '.keys' .sops.yaml | jq 'length')" \
    "bootstrap should register runtime and operator recipients"
  assert_eq "2" \
    "$(yq -o=json '.creation_rules[0].key_groups[0].age' .sops.yaml | jq 'length')" \
    "host rule should contain runtime and operator recipients"
  yq -o=json '.keys' .sops.yaml | jq -e \
    --arg operator "$operator_pubkey" \
    --arg runtime "$runtime_pubkey" \
    'sort == ([$operator, $runtime] | sort)' >/dev/null \
    || fail "bootstrap registered unexpected recipients"

  SOPS_AGE_KEY_FILE="$operator_key" \
    sops --decrypt secrets/main/newhost.yaml > "$WORKDIR/newhost.plain.yaml"
  assert_eq "REPLACE_ME" \
    "$(yq -r '.bootstrap.token' "$WORKDIR/newhost.plain.yaml")" \
    "bootstrap should encrypt the domain template"

  printf '==> patch an existing policy for another host\n'
  cp "$runtime_key" "$WORKDIR/runtime-age.before-second.txt"
  run_and_capture "$out" "${bootstrap_env[@]}" \
    bash "$bootstrap" --local secondhost
  assert_contains "$(cat "$out")" "Updated .sops.yaml."
  assert_contains "$(cat "$out")" \
    "Created encrypted secrets/main/secondhost.yaml."
  cmp -s "$WORKDIR/runtime-age.before-second.txt" "$runtime_key" \
    || fail "another local bootstrap should reuse the runtime age key"
  assert_eq "2" \
    "$(yq -o=json '.creation_rules' .sops.yaml | jq 'length')" \
    "bootstrap should append one host-specific rule"
  yq -o=json '.creation_rules' .sops.yaml | jq -e \
    --arg operator "$operator_pubkey" \
    --arg runtime "$runtime_pubkey" \
    '[.[] | select(.path_regex == "secrets/main/secondhost\\.yaml$")] as $rules
     | ($rules | length) == 1
       and (($rules[0].key_groups[0].age | sort)
         == ([$operator, $runtime] | sort))' >/dev/null \
    || fail "bootstrap should add the expected second-host recipient rule"
  SOPS_AGE_KEY_FILE="$operator_key" \
    sops --decrypt secrets/main/secondhost.yaml \
    > "$WORKDIR/secondhost.plain.yaml"
  assert_eq "REPLACE_ME" \
    "$(yq -r '.bootstrap.token' "$WORKDIR/secondhost.plain.yaml")" \
    "a patched policy should encrypt the domain template"

  cp secrets/main/newhost.yaml "$WORKDIR/newhost.before.yaml"
  cp "$runtime_key" "$WORKDIR/runtime-age.before.txt"

  printf '==> keep repeat bootstrap idempotent\n'
  run_and_capture "$out" "${bootstrap_env[@]}" \
    bash "$bootstrap" --local newhost
  assert_contains "$(cat "$out")" "secrets/main/newhost.yaml already exists."
  cmp -s "$WORKDIR/runtime-age.before.txt" "$runtime_key" \
    || fail "repeat bootstrap should reuse the runtime age key"
  cmp -s "$WORKDIR/newhost.before.yaml" secrets/main/newhost.yaml \
    || fail "repeat bootstrap should not rewrite an existing secret"
  assert_eq "2" "$(yq -o=json '.keys' .sops.yaml | jq 'length')" \
    "repeat bootstrap should not duplicate top-level recipients"
  assert_eq "2" \
    "$(yq -o=json '.creation_rules[0].key_groups[0].age' .sops.yaml | jq 'length')" \
    "repeat bootstrap should not duplicate rule recipients"
  yq -o=json '.keys' .sops.yaml | jq -e \
    --arg operator "$operator_pubkey" \
    --arg runtime "$runtime_pubkey" \
    'sort == ([$operator, $runtime] | sort)' >/dev/null \
    || fail "repeat bootstrap changed the recipient set"

  printf '==> sops bootstrap checks passed\n'
}

main "$@"
