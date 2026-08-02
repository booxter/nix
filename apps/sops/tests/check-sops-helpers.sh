#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../../.." && pwd)"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

log() {
  printf '==> %s\n' "$*"
}

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local message="${3:-}"
  if [[ "$expected" != "$actual" ]]; then
    if [[ -n "$message" ]]; then
      fail "$message (expected \"$expected\" but got \"$actual\")"
    fi
    fail "expected \"$expected\" but got \"$actual\""
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

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  local message="${3:-}"
  if [[ "$haystack" == *"$needle"* ]]; then
    fail "${message:-expected output not to contain \"$needle\"}"
  fi
}

assert_file_contains() {
  local file="$1"
  local needle="$2"
  local message="${3:-}"
  if ! grep -Fq -- "$needle" "$file"; then
    fail "${message:-expected \"$file\" to contain \"$needle\"}"
  fi
}

assert_yaml_scalar_eq_file() {
  local expected_file="$1"
  local yaml_file="$2"
  local query="$3"
  local message="${4:-}"
  local expected_json
  local actual_json

  expected_json="$(jq -Rs -c '.' < "$expected_file")"
  actual_json="$(yq -o=json "$query" "$yaml_file" | jq -c '.')"
  assert_eq "$expected_json" "$actual_json" "$message"
}

decrypt_secret_file() {
  local host="$1"
  local out_file="$2"
  sops --decrypt "secrets/main/${host}.yaml" > "$out_file"
}

encrypt_secret_file() {
  local host="$1"
  local plain_file="$2"
  local tmp_file
  tmp_file="$(mktemp)"
  sops --encrypt \
    --filename-override "secrets/main/${host}.yaml" \
    --input-type yaml \
    --output-type yaml \
    "$plain_file" > "$tmp_file"
  mv "$tmp_file" "secrets/main/${host}.yaml"
}

setup_repo() {
  local repo_dir="$1"
  mkdir -p "$repo_dir/secrets/main/_templates" "$repo_dir/apps/_helpers" "$repo_dir/apps/sops" "$repo_dir/tests"
  cp "$REPO_ROOT/apps/_helpers/host-aliases.sh" "$repo_dir/apps/_helpers/"
  cp "$REPO_ROOT/apps/_helpers/secret-domains.sh" "$repo_dir/apps/_helpers/"
  cp "$REPO_ROOT/apps/sops/sops-cat.sh" "$repo_dir/apps/sops/"
  cp "$REPO_ROOT/apps/sops/sops-update.sh" "$repo_dir/apps/sops/"
  cp "$REPO_ROOT/apps/sops/sops-copy.sh" "$repo_dir/apps/sops/"
  cp "$REPO_ROOT/apps/sops/sops-set.sh" "$repo_dir/apps/sops/"
  cp "$REPO_ROOT/apps/sops/sops-ups-sync.sh" "$repo_dir/apps/sops/"
  cp "$REPO_ROOT/apps/sops/sops-edit.sh" "$repo_dir/apps/sops/"
  cp "$REPO_ROOT/apps/sops/sops-pass.sh" "$repo_dir/apps/sops/"
  cp "$REPO_ROOT/apps/sops/tests/test-sops-config.sh" "$repo_dir/tests/"
  cd "$repo_dir"
  git init -q
  age-keygen -o "$repo_dir/age.txt" >/dev/null 2>&1
  export SOPS_AGE_KEY_FILE="$repo_dir/age.txt"
  export SOPS_MACHINE_HOSTNAME="test-host"
  export SOPS_SECRET_DOMAINS_FILE="$repo_dir/secret-domains.json"
  cat > "$SOPS_SECRET_DOMAINS_FILE" <<'EOF'
{
  "beast": "main",
  "cache": "main",
  "fana": "main",
  "gw": "main",
  "mair": "main",
  "prx1-lab": "main",
  "test-host": "main",
  "workhost": "work"
}
EOF
  local pubkey
  pubkey="$(age-keygen -y "$SOPS_AGE_KEY_FILE")"
  cat > "$repo_dir/.sops.yaml" <<EOF
keys:
  - ${pubkey}
creation_rules:
  - path_regex: secrets/main/.*\\.yaml\$
    key_groups:
      - age:
          - ${pubkey}
EOF
}

run_and_capture() {
  local out_file="$1"
  shift
  if ! "$@" >"$out_file" 2>&1; then
    cat "$out_file" >&2
    fail "command failed: $*"
  fi
}

run_with_stdin_and_capture() {
  local out_file="$1"
  local stdin_file="$2"
  shift 2
  if ! "$@" <"$stdin_file" >"$out_file" 2>&1; then
    cat "$out_file" >&2
    fail "command failed: $* < $stdin_file"
  fi
}

run_with_stdin_expect_failure() {
  local out_file="$1"
  local stdin_file="$2"
  shift 2
  if "$@" <"$stdin_file" >"$out_file" 2>&1; then
    cat "$out_file" >&2
    fail "expected command to fail: $* < $stdin_file"
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

test_age_recipient_derivation() {
  local helper="$REPO_ROOT/apps/sops/age-recipient.sh"
  local fixture_dir="$WORKDIR/age-recipient"
  local mock_bin="$fixture_dir/bin"
  local out="$fixture_dir/out.txt"
  local bash_path
  bash_path="$(command -v bash)"
  mkdir -p "$mock_bin"

  {
    printf '#!%s\n' "$bash_path"
    cat <<'EOF'
set -euo pipefail
[[ "$1" == "-y" && -f "$2" ]]
printf '%s\n' 'age1native1test'
EOF
  } > "$mock_bin/age-keygen"
  {
    printf '#!%s\n' "$bash_path"
    cat <<'EOF'
set -euo pipefail
[[ "$1" == "recipients" && "$2" == "-i" && -f "$3" ]]
printf '%s\n' 'age1se1test'
EOF
  } > "$mock_bin/age-plugin-se"
  chmod +x "$mock_bin/age-keygen" "$mock_bin/age-plugin-se"

  cat > "$fixture_dir/native.txt" <<'EOF'
# native identity
AGE-SECRET-KEY-1TEST
EOF
  cat > "$fixture_dir/se.txt" <<'EOF'
AGE-PLUGIN-SE-1TEST
EOF
  cat > "$fixture_dir/se-metadata.txt" <<'EOF'
# public key: age1se1metadata
AGE-PLUGIN-SE-1TEST
EOF
  cat > "$fixture_dir/yubikey.txt" <<'EOF'
# Recipient: age1yubikey1test
AGE-PLUGIN-YUBIKEY-1TEST
EOF
  cat > "$fixture_dir/yubikey-missing-metadata.txt" <<'EOF'
AGE-PLUGIN-YUBIKEY-1TEST
EOF
  cat > "$fixture_dir/yubikey-duplicate-metadata.txt" <<'EOF'
# Recipient: age1yubikey1test
# Recipient: age1yubikey1duplicate
AGE-PLUGIN-YUBIKEY-1TEST
EOF
  cat > "$fixture_dir/se-duplicate-metadata.txt" <<'EOF'
# public key: age1se1metadata
# public key: age1se1duplicate
AGE-PLUGIN-SE-1TEST
EOF
  cat > "$fixture_dir/unknown.txt" <<'EOF'
AGE-PLUGIN-UNKNOWN-1TEST
EOF

  run_and_capture "$out" env PATH="$mock_bin:$PATH" bash "$helper" "$fixture_dir/native.txt"
  assert_eq "age1native1test" "$(cat "$out")" "native identity should use age-keygen"

  run_and_capture "$out" env PATH="$mock_bin:$PATH" bash "$helper" "$fixture_dir/se.txt"
  assert_eq "age1se1test" "$(cat "$out")" "SE identity should use age-plugin-se"

  run_and_capture "$out" env PATH="$mock_bin:$PATH" bash "$helper" "$fixture_dir/se-metadata.txt"
  assert_eq "age1se1metadata" "$(cat "$out")" "SE identity should use embedded recipient when present"

  run_and_capture "$out" env PATH="$mock_bin:$PATH" bash "$helper" "$fixture_dir/yubikey.txt"
  assert_eq "age1yubikey1test" "$(cat "$out")" "YubiKey identity should use embedded recipient"

  run_expect_failure "$out" bash "$helper" "$fixture_dir/missing.txt"
  assert_contains "$(cat "$out")" "Age identity file not found"

  run_expect_failure "$out" env PATH="$mock_bin:$PATH" \
    bash "$helper" "$fixture_dir/se-duplicate-metadata.txt"
  assert_contains "$(cat "$out")" "multiple recipient metadata lines"

  run_expect_failure "$out" bash "$helper" "$fixture_dir/yubikey-missing-metadata.txt"
  assert_contains "$(cat "$out")" "must contain exactly one recipient metadata line"

  run_expect_failure "$out" bash "$helper" "$fixture_dir/yubikey-duplicate-metadata.txt"
  assert_contains "$(cat "$out")" "must contain exactly one recipient metadata line"

  run_expect_failure "$out" bash "$helper" "$fixture_dir/unknown.txt"
  assert_contains "$(cat "$out")" "Unsupported age identity type"
}

main() {
  local repo="$WORKDIR/repo"
  local out="$WORKDIR/out.txt"
  local before="$WORKDIR/before.yaml"
  local after="$WORKDIR/after.yaml"
  local edited="$WORKDIR/edited.yaml"
  local copied="$WORKDIR/copied.yaml"

  log "derive recipients from native, Secure Enclave, and YubiKey identities"
  test_age_recipient_derivation

  setup_repo "$repo"

  cat > "$repo/secrets/main/_template.yaml" <<'EOF'
common:
  shared: "TEMPLATE"
attic:
  token: "REPLACE_ME"
  endpoint: "http://nix-cache:8080"
flakehub:
  token: "REPLACE_ME"
users:
  root:
    hashedPassword: "REPLACE_ME"
  ihrachyshka:
    hashedPassword: "REPLACE_ME"
EOF

  cat > "$repo/secrets/main/_templates/beast.yaml" <<'EOF'
jellyfin:
  apiKey: "REPLACE_ME"
transmission:
  trackers:
    - "REPLACE_ME"
EOF

  cat > "$repo/beast.plain.yaml" <<'EOF'
common:
  shared: "SECRET"
other:
  keep: "beast"
EOF

  cat > "$repo/mair.plain.yaml" <<'EOF'
attic:
  token: "NEW_TOKEN"
  endpoint: "http://nix-cache:8080"
other:
  keep: "src"
EOF

  cat > "$repo/prx1-lab.plain.yaml" <<'EOF'
attic:
  token: "OLD_TOKEN"
nut:
  users:
    upsslave:
      password: "LAB_UPS_PASS"
other:
  keep: "dst"
EOF

  cat > "$repo/cache.plain.yaml" <<'EOF'
nut:
  monitors:
    prx1-lab:
      password: "OLD_UPS_PASS"
other:
  keep: "cache"
EOF

  cat > "$repo/fana.plain.yaml" <<'EOF'
other:
  keep: "fana"
EOF

  cat > "$repo/gw.plain.yaml" <<'EOF'
users:
  root:
    hashedPassword: "REPLACE_ME"
  ihrachyshka:
    hashedPassword: "REPLACE_ME"
other:
  keep: "gw"
EOF

  cd "$repo"
  encrypt_secret_file beast "$repo/beast.plain.yaml"
  encrypt_secret_file mair "$repo/mair.plain.yaml"
  encrypt_secret_file prx1-lab "$repo/prx1-lab.plain.yaml"
  encrypt_secret_file cache "$repo/cache.plain.yaml"
  encrypt_secret_file fana "$repo/fana.plain.yaml"
  encrypt_secret_file gw "$repo/gw.plain.yaml"

  log "validate encrypted secret layout"
  run_and_capture "$out" bash "$repo/tests/test-sops-config.sh"
  assert_contains "$(cat "$out")" "sops config check passed."

  log "reject recipients shared across secret domains"
  local main_pubkey
  local work_pubkey
  local work_identity
  main_pubkey="$(age-keygen -y "$SOPS_AGE_KEY_FILE")"
  yq -i ".creation_rules += [{\"path_regex\":\"secrets/work/.*\\\\.yaml$\",\"key_groups\":[{\"age\":[\"${main_pubkey}\"]}]}]" .sops.yaml
  run_expect_failure "$out" bash "$repo/tests/test-sops-config.sh"
  assert_contains "$(cat "$out")" "share age recipients"

  age-keygen -o "$repo/work-age.txt" >/dev/null 2>&1
  work_pubkey="$(age-keygen -y "$repo/work-age.txt")"
  yq -i ".keys += [\"${work_pubkey}\"] | (.creation_rules[] | select(.path_regex == \"secrets/work/.*\\\\.yaml$\") | .key_groups[]?.age) = [\"${work_pubkey}\"]" .sops.yaml
  run_and_capture "$out" bash "$repo/tests/test-sops-config.sh"
  assert_contains "$(cat "$out")" "sops config check passed."

  log "reject a non-map SOPS policy"
  cp .sops.yaml "$WORKDIR/sops.valid.yaml"

  printf '%s\n' '- not-a-map' > .sops.yaml
  run_expect_failure "$out" bash "$repo/tests/test-sops-config.sh"
  assert_contains "$(cat "$out")" ".sops.yaml must be a YAML map at top-level."
  cp "$WORKDIR/sops.valid.yaml" .sops.yaml

  log "reject an empty SOPS recipient list"
  yq -i '.keys = []' .sops.yaml
  run_expect_failure "$out" bash "$repo/tests/test-sops-config.sh"
  assert_contains "$(cat "$out")" "'keys' sequence must not be empty."
  cp "$WORKDIR/sops.valid.yaml" .sops.yaml

  log "reject a non-sequence SOPS recipient list"
  yq -i '.keys = {}' .sops.yaml
  run_expect_failure "$out" bash "$repo/tests/test-sops-config.sh"
  assert_contains "$(cat "$out")" \
    ".sops.yaml must contain a top-level 'keys' sequence."
  cp "$WORKDIR/sops.valid.yaml" .sops.yaml

  log "reject an empty SOPS creation rule list"
  yq -i '.creation_rules = []' .sops.yaml
  run_expect_failure "$out" bash "$repo/tests/test-sops-config.sh"
  assert_contains "$(cat "$out")" "'creation_rules' sequence must not be empty."
  cp "$WORKDIR/sops.valid.yaml" .sops.yaml

  log "reject a non-sequence SOPS creation rule list"
  yq -i '.creation_rules = {}' .sops.yaml
  run_expect_failure "$out" bash "$repo/tests/test-sops-config.sh"
  assert_contains "$(cat "$out")" \
    ".sops.yaml must contain a top-level 'creation_rules' sequence."
  cp "$WORKDIR/sops.valid.yaml" .sops.yaml

  log "reject plaintext files in secret directories"
  printf '%s\n' 'plaintext: secret' > secrets/main/plain.yaml
  run_expect_failure "$out" bash "$repo/tests/test-sops-config.sh"
  assert_contains "$(cat "$out")" "secrets/main/plain.yaml is missing a 'sops' block"
  rm secrets/main/plain.yaml

  log "require a SOPS policy when secret files exist"
  mv .sops.yaml "$WORKDIR/sops.missing.yaml"
  run_expect_failure "$out" bash "$repo/tests/test-sops-config.sh"
  assert_contains "$(cat "$out")" ".sops.yaml is missing."
  mv "$WORKDIR/sops.missing.yaml" .sops.yaml

  log "decrypt a non-main domain with its dedicated operator identity"
  if [[ "$(uname -s)" == "Darwin" ]]; then
    work_identity="$WORKDIR/home/Library/Application Support/sops/age/work.txt"
  else
    work_identity="$WORKDIR/xdg/sops/age/work.txt"
  fi
  mkdir -p "$repo/secrets/work" "$(dirname -- "$work_identity")"
  cp "$repo/work-age.txt" "$work_identity"
  cat > "$WORKDIR/workhost.plain.yaml" <<'EOF'
domain:
  marker: "WORK_ONLY"
EOF
  SOPS_AGE_KEY_FILE="$repo/work-age.txt" \
    sops --encrypt \
    --filename-override "secrets/work/workhost.yaml" \
    --input-type yaml \
    --output-type yaml \
    "$WORKDIR/workhost.plain.yaml" > secrets/work/workhost.yaml
  run_and_capture "$out" env -u SOPS_AGE_KEY_FILE \
    HOME="$WORKDIR/home" \
    XDG_CONFIG_HOME="$WORKDIR/xdg" \
    SOPS_MACHINE_HOSTNAME=test-host \
    SOPS_SECRET_DOMAINS_FILE="$SOPS_SECRET_DOMAINS_FILE" \
    bash "$repo/apps/sops/sops-cat.sh" --domain work workhost
  assert_contains "$(cat "$out")" "marker: WORK_ONLY"

  mkdir -p "$WORKDIR/missing-home" "$WORKDIR/missing-xdg"
  run_expect_failure "$out" env -u SOPS_AGE_KEY_FILE \
    HOME="$WORKDIR/missing-home" \
    XDG_CONFIG_HOME="$WORKDIR/missing-xdg" \
    SOPS_MACHINE_HOSTNAME=test-host \
    SOPS_SECRET_DOMAINS_FILE="$SOPS_SECRET_DOMAINS_FILE" \
    bash "$repo/apps/sops/sops-cat.sh" --domain work workhost
  assert_contains "$(cat "$out")" "Age identity for secret domain 'work' not found:"

  run_expect_failure "$out" bash "$repo/apps/sops/sops-cat.sh" --domain Invalid beast
  assert_contains "$(cat "$out")" "Invalid secret domain: Invalid"

  run_expect_failure "$out" env -u SOPS_SECRET_DOMAINS_FILE \
    bash "$repo/apps/sops/sops-cat.sh" beast
  assert_contains "$(cat "$out")" \
    "SOPS_SECRET_DOMAINS_FILE is not set to a readable inventory map."

  log "default host to the current short hostname"
  mkdir -p "$WORKDIR/hostname-bin"
  cat > "$WORKDIR/hostname-bin/hostname" <<'EOF'
#!/bin/sh
set -eu
[ "${1:-}" = "-s" ]
printf '%s\n' beast
EOF
  chmod +x "$WORKDIR/hostname-bin/hostname"
  run_and_capture "$out" env PATH="$WORKDIR/hostname-bin:$PATH" \
    bash "$repo/apps/sops/sops-cat.sh"
  assert_contains "$(cat "$out")" "keep: beast"

  log "merge default and host template keys into beast"
  local beast_common_cipher_before
  local beast_other_cipher_before
  beast_common_cipher_before="$(yq -r '.common.shared' "secrets/main/beast.yaml")"
  beast_other_cipher_before="$(yq -r '.other.keep' "secrets/main/beast.yaml")"
  run_and_capture "$out" bash "$repo/apps/sops/sops-update.sh" beast
  assert_contains "$(cat "$out")" "Updated secret from templates:"
  assert_eq "$beast_common_cipher_before" "$(yq -r '.common.shared' "secrets/main/beast.yaml")" "sops-update should preserve unchanged existing ciphertext"
  assert_eq "$beast_other_cipher_before" "$(yq -r '.other.keep' "secrets/main/beast.yaml")" "sops-update should preserve unrelated existing ciphertext"
  decrypt_secret_file beast "$after"
  assert_eq "SECRET" "$(yq -r '.common.shared' "$after")" "beast shared value should be preserved"
  assert_eq "beast" "$(yq -r '.other.keep' "$after")" "beast unrelated data should survive update"
  assert_eq "REPLACE_ME" "$(yq -r '.attic.token' "$after")" "default template block should be added"
  assert_eq "REPLACE_ME" "$(yq -r '.flakehub.token' "$after")" "flakehub token placeholder should be added"
  assert_eq "REPLACE_ME" "$(yq -r '.users.root.hashedPassword' "$after")" "root password placeholder should be added"
  assert_eq "REPLACE_ME" "$(yq -r '.users.ihrachyshka.hashedPassword' "$after")" "user password placeholder should be added"
  assert_eq "REPLACE_ME" "$(yq -r '.jellyfin.apiKey' "$after")" "host template block should be added"
  assert_eq "REPLACE_ME" "$(yq -r '.transmission.trackers[0]' "$after")" "host template array values should be added"
  assert_file_contains "secrets/main/beast.yaml" "sops:"

  log "skip re-encryption when beast is already converged"
  cp "secrets/main/beast.yaml" "$before"
  run_and_capture "$out" bash "$repo/apps/sops/sops-update.sh" beast
  assert_contains "$(cat "$out")" "Secret already up to date:"
  cmp -s "$before" "secrets/main/beast.yaml" || fail "no-op update should not rewrite encrypted secret"

  log "force re-encrypt without changing decrypted content"
  decrypt_secret_file beast "$before"
  yq -o=json '.' "$before" | jq -S . > "$WORKDIR/before-force.json"
  cp "secrets/main/beast.yaml" "$WORKDIR/before-force.yaml"
  run_and_capture "$out" bash "$repo/apps/sops/sops-update.sh" --force beast
  assert_contains "$(cat "$out")" "Re-encrypted secret:"
  decrypt_secret_file beast "$after"
  yq -o=json '.' "$after" | jq -S . > "$WORKDIR/after-force.json"
  cmp -s "$WORKDIR/before-force.json" "$WORKDIR/after-force.json" || fail "forced re-encrypt changed decrypted beast secret"
  if cmp -s "$WORKDIR/before-force.yaml" "secrets/main/beast.yaml"; then
    fail "forced re-encrypt should rewrite encrypted beast secret"
  fi

  log "merge an empty template container"
  yq -i '.emptyBlock = {}' secrets/main/_template.yaml
  run_and_capture "$out" bash "$repo/apps/sops/sops-update.sh" beast
  assert_contains "$(cat "$out")" "Updated secret from templates:"
  decrypt_secret_file beast "$after"
  assert_eq "object" \
    "$(yq -o=json '.emptyBlock' "$after" | jq -r 'type')" \
    "an empty template map should still be added"
  assert_eq "0" \
    "$(yq -o=json '.emptyBlock' "$after" | jq -r 'length')" \
    "the empty template map should remain empty"
  yq -i 'del(.emptyBlock)' secrets/main/_template.yaml

  log "silence a converged update when requested"
  run_and_capture "$out" env SOPS_UPDATE_QUIET=1 \
    bash "$repo/apps/sops/sops-update.sh" beast
  assert_eq "" "$(cat "$out")" "quiet no-op update should produce no output"

  log "copy a secret block without losing destination data"
  local prx_other_cipher_before
  local prx_ups_cipher_before
  prx_other_cipher_before="$(yq -r '.other.keep' "secrets/main/prx1-lab.yaml")"
  prx_ups_cipher_before="$(yq -r '.nut.users.upsslave.password' "secrets/main/prx1-lab.yaml")"
  run_and_capture "$out" bash "$repo/apps/sops/sops-copy.sh" mair prx1-lab attic
  assert_contains "$(cat "$out")" "Copied attic from mair to prx1-lab."
  assert_eq "$prx_other_cipher_before" "$(yq -r '.other.keep' "secrets/main/prx1-lab.yaml")" "sops-copy should preserve unrelated ciphertext"
  assert_eq "$prx_ups_cipher_before" "$(yq -r '.nut.users.upsslave.password' "secrets/main/prx1-lab.yaml")" "sops-copy should preserve destination-only ciphertext"
  decrypt_secret_file prx1-lab "$copied"
  assert_eq "NEW_TOKEN" "$(yq -r '.attic.token' "$copied")"
  assert_eq "http://nix-cache:8080" "$(yq -r '.attic.endpoint' "$copied")"
  assert_eq "dst" "$(yq -r '.other.keep' "$copied")" "destination-specific values should survive copy"
  assert_eq "LAB_UPS_PASS" "$(yq -r '.nut.users.upsslave.password' "$copied")" "destination secret values should survive copy"

  log "update a prox VM secret by short name"
  run_and_capture "$out" bash "$repo/apps/sops/sops-update.sh" gw
  assert_contains "$(cat "$out")" "Updated secret from templates:"
  assert_contains "$(cat "$out")" "secrets/main/gw.yaml"
  decrypt_secret_file gw "$after"
  assert_eq "REPLACE_ME" "$(yq -r '.attic.token' "$after")" "short prox VM update should merge templates into short secret"
  assert_eq "gw" "$(yq -r '.other.keep' "$after")" "short prox VM update should preserve short secret data"

  log "copy a secret value to a different destination path"
  run_and_capture "$out" bash "$repo/apps/sops/sops-copy.sh" \
    prx1-lab cache \
    nut/users/upsslave/password \
    nut/monitors/prx1-lab/password
  assert_contains "$(cat "$out")" "Copied nut/users/upsslave/password from prx1-lab to cache:nut/monitors/prx1-lab/password."
  decrypt_secret_file cache "$copied"
  assert_eq "LAB_UPS_PASS" "$(yq -r '.nut.monitors."prx1-lab".password' "$copied")"
  assert_eq "cache" "$(yq -r '.other.keep' "$copied")" "destination-specific values should survive copy"

  log "set a secret value from stdin without losing destination data"
  local cache_other_cipher_before
  local cache_ups_cipher_before
  local set_stdin_value="$WORKDIR/set-stdin-value.txt"
  printf 'SET_FROM_STDIN\n' > "$set_stdin_value"
  cache_other_cipher_before="$(yq -r '.other.keep' "secrets/main/cache.yaml")"
  cache_ups_cipher_before="$(yq -r '.nut.monitors."prx1-lab".password' "secrets/main/cache.yaml")"
  run_with_stdin_and_capture "$out" "$set_stdin_value" bash "$repo/apps/sops/sops-set.sh" cache nested/new/value
  assert_contains "$(cat "$out")" "Updated cache:nested/new/value."
  assert_eq "$cache_other_cipher_before" "$(yq -r '.other.keep' "secrets/main/cache.yaml")" "sops-set should preserve unrelated ciphertext"
  assert_eq "$cache_ups_cipher_before" "$(yq -r '.nut.monitors."prx1-lab".password' "secrets/main/cache.yaml")" "sops-set should preserve existing nested ciphertext"
  decrypt_secret_file cache "$copied"
  assert_yaml_scalar_eq_file "$set_stdin_value" "$copied" '.nested.new.value' "sops-set should preserve exact stdin bytes"
  assert_eq "LAB_UPS_PASS" "$(yq -r '.nut.monitors."prx1-lab".password' "$copied")"
  assert_eq "cache" "$(yq -r '.other.keep' "$copied")" "destination-specific values should survive set"

  cp "secrets/main/cache.yaml" "$before"
  run_with_stdin_and_capture "$out" "$set_stdin_value" bash "$repo/apps/sops/sops-set.sh" cache nested/new/value
  cmp -s "$before" "secrets/main/cache.yaml" || fail "idempotent sops-set should not rewrite an equal value"

  log "set preserves leading, trailing, and final whitespace"
  local whitespace_value="$WORKDIR/sops-set-whitespace-value.txt"
  printf ' leading space\nline with trailing spaces   \nfinal newline preserved\n' > "$whitespace_value"
  run_with_stdin_and_capture "$out" "$whitespace_value" bash "$repo/apps/sops/sops-set.sh" cache nested/whitespace/value
  assert_contains "$(cat "$out")" "Updated cache:nested/whitespace/value."
  decrypt_secret_file cache "$copied"
  assert_yaml_scalar_eq_file "$whitespace_value" "$copied" '.nested.whitespace.value' "sops-set should preserve leading, trailing, and final whitespace"

  log "treat dots and dashes as literal path characters"
  local special_key='key.with.dots-and-dashes'
  local special_path="special/${special_key}"
  local special_value="$WORKDIR/sops-special-value.txt"
  local expected_special_json
  local actual_special_json
  printf 'SPECIAL_VALUE\n' > "$special_value"
  run_with_stdin_and_capture "$out" "$special_value" \
    bash "$repo/apps/sops/sops-set.sh" cache "$special_path"
  decrypt_secret_file cache "$copied"
  expected_special_json="$(jq -Rs -c '.' < "$special_value")"
  actual_special_json="$(
    yq -o=json '.' "$copied" \
      | jq -c --arg key "$special_key" '.special[$key]'
  )"
  assert_eq "$expected_special_json" "$actual_special_json" \
    "sops-set should treat dots and dashes as literal key characters"

  run_and_capture "$out" bash "$repo/apps/sops/sops-copy.sh" \
    cache prx1-lab "$special_path" "copied/${special_key}"
  decrypt_secret_file prx1-lab "$copied"
  actual_special_json="$(
    yq -o=json '.' "$copied" \
      | jq -c --arg key "$special_key" '.copied[$key]'
  )"
  assert_eq "$expected_special_json" "$actual_special_json" \
    "sops-copy should preserve literal path segments and the exact value"

  cp secrets/main/prx1-lab.yaml "$before"
  run_and_capture "$out" bash "$repo/apps/sops/sops-copy.sh" \
    cache prx1-lab "$special_path" "copied/${special_key}"
  cmp -s "$before" secrets/main/prx1-lab.yaml \
    || fail "idempotent sops-copy should not rewrite an equal value"

  log "sync UPS monitor password through helper"
  cat > "$repo/ups-clients-by-server.json" <<'EOF'
{"prx1-lab":["fana"]}
EOF
  run_and_capture "$out" env UPS_CLIENTS_BY_SERVER_FILE="$repo/ups-clients-by-server.json" \
    bash "$repo/apps/sops/sops-ups-sync.sh" prx1-lab
  assert_contains "$(cat "$out")" "Synced prx1-lab UPS password to fana."
  decrypt_secret_file fana "$copied"
  assert_eq "LAB_UPS_PASS" "$(yq -r '.nut.monitors."prx1-lab".password' "$copied")"
  assert_eq "fana" "$(yq -r '.other.keep' "$copied")" "destination-specific values should survive sync"

  log "let explicit UPS clients override inventory defaults"
  local sentinel_value="$WORKDIR/ups-sentinel.txt"
  printf 'DO_NOT_TOUCH' > "$sentinel_value"
  run_with_stdin_and_capture "$out" "$sentinel_value" \
    bash "$repo/apps/sops/sops-set.sh" fana nut/monitors/prx1-lab/password
  run_and_capture "$out" env UPS_CLIENTS_BY_SERVER_FILE="$repo/ups-clients-by-server.json" \
    bash "$repo/apps/sops/sops-ups-sync.sh" prx1-lab gw
  assert_contains "$(cat "$out")" "Synced prx1-lab UPS password to gw."
  assert_not_contains "$(cat "$out")" "to fana"
  decrypt_secret_file gw "$copied"
  assert_eq "LAB_UPS_PASS" "$(yq -r '.nut.monitors."prx1-lab".password' "$copied")"
  decrypt_secret_file fana "$copied"
  assert_eq "DO_NOT_TOUCH" "$(yq -r '.nut.monitors."prx1-lab".password' "$copied")" \
    "an explicit client list should not also use inventory clients"

  log "sync every UPS server from inventory"
  run_and_capture "$out" env UPS_CLIENTS_BY_SERVER_FILE="$repo/ups-clients-by-server.json" \
    bash "$repo/apps/sops/sops-ups-sync.sh" --all
  assert_contains "$(cat "$out")" "Synced prx1-lab UPS password to fana."
  decrypt_secret_file fana "$copied"
  assert_eq "LAB_UPS_PASS" "$(yq -r '.nut.monitors."prx1-lab".password' "$copied")"

  log "handle empty UPS client selections explicitly"
  run_and_capture "$out" env UPS_CLIENTS_BY_SERVER_FILE="$repo/ups-clients-by-server.json" \
    bash "$repo/apps/sops/sops-ups-sync.sh" unknown-server
  assert_contains "$(cat "$out")" "No UPS clients to sync for unknown-server."
  printf '%s\n' '{}' > "$WORKDIR/no-ups-clients.json"
  run_expect_failure "$out" env UPS_CLIENTS_BY_SERVER_FILE="$WORKDIR/no-ups-clients.json" \
    bash "$repo/apps/sops/sops-ups-sync.sh" --all
  assert_contains "$(cat "$out")" "No UPS clients found in inventory."

  log "fail cleanly when source path is missing"
  cp secrets/main/prx1-lab.yaml "$before"
  run_expect_failure "$out" bash "$repo/apps/sops/sops-copy.sh" mair prx1-lab missing
  assert_contains "$(cat "$out")" "Path not found in source secret: missing"
  cmp -s "$before" secrets/main/prx1-lab.yaml \
    || fail "a missing copy source path should not modify the destination"

  log "fail cleanly for missing files and empty key paths"
  run_expect_failure "$out" bash "$repo/apps/sops/sops-copy.sh" mair missing attic
  assert_contains "$(cat "$out")" "Destination secret not found:"
  run_expect_failure "$out" bash "$repo/apps/sops/sops-copy.sh" mair cache '///'
  assert_contains "$(cat "$out")" "KEY_PATH must not be empty."
  run_with_stdin_expect_failure "$out" "$special_value" \
    bash "$repo/apps/sops/sops-set.sh" cache '///'
  assert_contains "$(cat "$out")" "KEY_PATH must not be empty."
  run_expect_failure "$out" bash "$repo/apps/sops/sops-cat.sh" missing
  assert_contains "$(cat "$out")" "Secret not found:"
  run_expect_failure "$out" bash "$repo/apps/sops/sops-edit.sh" missing
  assert_contains "$(cat "$out")" "Secret not found:"
  run_expect_failure "$out" bash "$repo/apps/sops/sops-update.sh" missing
  assert_contains "$(cat "$out")" "Secret not found:"
  run_with_stdin_expect_failure "$out" "$special_value" \
    bash "$repo/apps/sops/sops-set.sh" missing some/path
  assert_contains "$(cat "$out")" "Secret not found:"

  cp secrets/main/beast.yaml "$before"
  mv secrets/main/_template.yaml "$WORKDIR/main-template.yaml"
  run_expect_failure "$out" bash "$repo/apps/sops/sops-update.sh" beast
  assert_contains "$(cat "$out")" "Template not found:"
  mv "$WORKDIR/main-template.yaml" secrets/main/_template.yaml
  cmp -s "$before" secrets/main/beast.yaml \
    || fail "a missing template should not modify the secret"

  log "set a login password hash from pass without losing existing secret data"
  mkdir -p "$WORKDIR/fake-bin" "$WORKDIR/pass-store"
  cat > "$WORKDIR/fake-bin/pass" <<'EOF'
#!/bin/sh
set -eu

cmd="$1"
shift
printf '%s\n' "$cmd $*" >> "${PASS_TEST_LOG:-/dev/null}"

case "$cmd" in
  insert)
    multiline=0
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --multiline | -m)
          multiline=1
          shift
          ;;
        --force | -f)
          shift
          ;;
        --echo | -e)
          shift
          ;;
        -*)
          echo "unexpected pass insert option: $1" >&2
          exit 2
          ;;
        *)
          break
          ;;
      esac
    done
    entry="$1"
    mkdir -p "$PASS_TEST_STORE/$(dirname "$entry")"
    if [ "$multiline" = 1 ]; then
      cat > "$PASS_TEST_STORE/$entry"
    else
      printf 'inserted-password-for-%s\n' "$entry" > "$PASS_TEST_STORE/$entry"
    fi
    ;;
  generate)
    if [ "${1:-}" = "--force" ]; then
      shift
    fi
    entry="$1"
    mkdir -p "$PASS_TEST_STORE/$(dirname "$entry")"
    printf 'generated-password-for-%s\n' "$entry" > "$PASS_TEST_STORE/$entry"
    printf 'generated-password-for-%s\n' "$entry"
    ;;
  show)
    entry="$1"
    if [ "${PASS_TEST_EMPTY:-0}" = 1 ]; then
      printf '\n'
    else
      cat "$PASS_TEST_STORE/$entry"
    fi
    ;;
  *)
    echo "unexpected pass command: $cmd" >&2
    exit 2
    ;;
esac
EOF
  chmod +x "$WORKDIR/fake-bin/pass"
  local beast_other_cipher_before_pass
  beast_other_cipher_before_pass="$(yq -r '.other.keep' "secrets/main/beast.yaml")"
  run_and_capture "$out" env \
    PASS_TEST_STORE="$WORKDIR/pass-store" \
    PATH="$WORKDIR/fake-bin:$PATH" \
    bash "$repo/apps/sops/sops-pass.sh" beast root
  assert_contains "$(cat "$out")" "Updated users/root/hashedPassword"
  assert_contains "$(cat "$out")" "Inserted host/beast/root."
  assert_eq "$beast_other_cipher_before_pass" "$(yq -r '.other.keep' "secrets/main/beast.yaml")" "sops-pass should preserve unrelated ciphertext"
  decrypt_secret_file beast "$after"
  local sha512_prefix="\$6\$"
  case "$(yq -r '.users.root.hashedPassword' "$after")" in
    "${sha512_prefix}"*) ;;
    *) fail "root password hash should use sha-512 crypt format" ;;
  esac
  assert_eq "REPLACE_ME" "$(yq -r '.users.ihrachyshka.hashedPassword' "$after")" "other login password should not be touched"
  assert_eq "beast" "$(yq -r '.other.keep' "$after")" "unrelated data should survive password update"
  test -f "$WORKDIR/pass-store/host/beast/root" || fail "default sops-pass should insert into pass"

  log "generate login password in pass using a short VM host name"
  run_and_capture "$out" env \
    PASS_TEST_STORE="$WORKDIR/pass-store" \
    PATH="$WORKDIR/fake-bin:$PATH" \
    bash "$repo/apps/sops/sops-pass.sh" --gen gw root
  assert_contains "$(cat "$out")" "Generated host/gw/root."
  test -f "$WORKDIR/pass-store/host/gw/root" || fail "pass entry should use short VM host name"
  decrypt_secret_file gw "$after"
  case "$(yq -r '.users.root.hashedPassword' "$after")" in
    "${sha512_prefix}"*) ;;
    *) fail "generated root password hash should use sha-512 crypt format" ;;
  esac
  assert_eq "REPLACE_ME" "$(yq -r '.users.ihrachyshka.hashedPassword' "$after")" "generated password should only update requested user"

  log "honor pass prefix and generated password length"
  : > "$WORKDIR/pass.log"
  run_and_capture "$out" env \
    PASS_TEST_LOG="$WORKDIR/pass.log" \
    PASS_TEST_STORE="$WORKDIR/pass-store" \
    SOPS_PASS_GENERATE_LENGTH=47 \
    SOPS_PASS_PREFIX=machines \
    PATH="$WORKDIR/fake-bin:$PATH" \
    bash "$repo/apps/sops/sops-pass.sh" --gen beast ihrachyshka
  assert_contains "$(cat "$out")" "Generated machines/beast/ihrachyshka."
  assert_file_contains "$WORKDIR/pass.log" \
    "generate --force machines/beast/ihrachyshka 47"
  decrypt_secret_file beast "$after"
  case "$(yq -r '.users.ihrachyshka.hashedPassword' "$after")" in
    "${sha512_prefix}"*) ;;
    *) fail "custom pass entry should still produce a sha-512 hash" ;;
  esac

  log "decrypt a VM secret by short name"
  run_and_capture "$out" bash "$repo/apps/sops/sops-cat.sh" gw
  assert_contains "$(cat "$out")" "other:"
  assert_contains "$(cat "$out")" "keep: gw"

  log "update both login users with one generated password"
  run_and_capture "$out" env \
    PASS_TEST_STORE="$WORKDIR/pass-store" \
    PATH="$WORKDIR/fake-bin:$PATH" \
    bash "$repo/apps/sops/sops-pass.sh" --gen gw both
  assert_contains "$(cat "$out")" "Generated host/gw/root and host/gw/ihrachyshka."
  assert_contains "$(cat "$out")" "Updated users/root/hashedPassword and users/ihrachyshka/hashedPassword"
  test ! -f "$WORKDIR/pass-store/host/gw/both" || fail "both should not create a synthetic pass user"
  assert_eq "$(cat "$WORKDIR/pass-store/host/gw/root")" "$(cat "$WORKDIR/pass-store/host/gw/ihrachyshka")" "both should write the same pass value to both real users"
  decrypt_secret_file gw "$after"
  local root_hash
  local user_hash
  root_hash="$(yq -r '.users.root.hashedPassword' "$after")"
  user_hash="$(yq -r '.users.ihrachyshka.hashedPassword' "$after")"
  case "$root_hash" in
    "${sha512_prefix}"*) ;;
    *) fail "both user root hash should use sha-512 crypt format" ;;
  esac
  assert_eq "$root_hash" "$user_hash" "both user should write the same hash to both accounts"

  log "reject unsupported login users before prompting"
  run_expect_failure "$out" bash "$repo/apps/sops/sops-pass.sh" beast nobody
  assert_contains "$(cat "$out")" "Unsupported user: nobody"

  log "reject password failures without modifying encrypted secrets"
  cp secrets/main/gw.yaml "$before"
  run_expect_failure "$out" env \
    PASS_TEST_EMPTY=1 \
    PASS_TEST_STORE="$WORKDIR/pass-store" \
    PATH="$WORKDIR/fake-bin:$PATH" \
    bash "$repo/apps/sops/sops-pass.sh" gw root
  assert_contains "$(cat "$out")" "Stored password must not be empty:"
  cmp -s "$before" secrets/main/gw.yaml \
    || fail "an empty stored password should not modify the secret"

  mkdir -p "$WORKDIR/bad-hash-bin"
  cat > "$WORKDIR/bad-hash-bin/mkpasswd" <<'EOF'
#!/bin/sh
set -eu
cat >/dev/null
printf '%s\n' not-a-password-hash
EOF
  chmod +x "$WORKDIR/bad-hash-bin/mkpasswd"
  run_expect_failure "$out" env \
    PASS_TEST_STORE="$WORKDIR/pass-store" \
    PATH="$WORKDIR/bad-hash-bin:$WORKDIR/fake-bin:$PATH" \
    bash "$repo/apps/sops/sops-pass.sh" gw root
  assert_contains "$(cat "$out")" "mkpasswd returned an unexpected hash format."
  cmp -s "$before" secrets/main/gw.yaml \
    || fail "an invalid password hash should not modify the secret"

  : > "$WORKDIR/pass.log"
  run_expect_failure "$out" env \
    PASS_TEST_LOG="$WORKDIR/pass.log" \
    PASS_TEST_STORE="$WORKDIR/pass-store" \
    PATH="$WORKDIR/fake-bin:$PATH" \
    bash "$repo/apps/sops/sops-pass.sh" missing root
  assert_contains "$(cat "$out")" "Secret not found for host missing:"
  assert_eq "" "$(cat "$WORKDIR/pass.log")" \
    "a missing secret should fail before invoking pass"

  log "edit a secret through sops without merging template keys"
  cat > "$WORKDIR/editor.sh" <<'EOF'
#!/bin/sh
set -eu
yq -i '.attic.token = "EDITED_TOKEN" | .editorTouched = true' "$1"
EOF
  chmod +x "$WORKDIR/editor.sh"
  run_and_capture "$out" env EDITOR="$WORKDIR/editor.sh" bash "$repo/apps/sops/sops-edit.sh" prx1-lab
  decrypt_secret_file prx1-lab "$edited"
  assert_eq "EDITED_TOKEN" "$(yq -r '.attic.token' "$edited")"
  assert_eq "dst" "$(yq -r '.other.keep' "$edited")"
  assert_eq "true" "$(yq -r '.editorTouched' "$edited")"
  assert_eq "null" "$(yq -r '.flakehub.token' "$edited")" "sops-edit should not merge template-only keys"

  log "preserve encryption after sequential helper calls"
  decrypt_secret_file beast "$before"
  decrypt_secret_file prx1-lab "$after"
  assert_not_contains "$(cat "$before")" "ENC[" "decrypted beast secret should be plaintext"
  assert_not_contains "$(cat "$after")" "ENC[" "decrypted prx1-lab secret should be plaintext"
  assert_file_contains "secrets/main/beast.yaml" "ENC["
  assert_file_contains "secrets/main/prx1-lab.yaml" "ENC["

  log "sops helper integration checks passed"
}

main "$@"
