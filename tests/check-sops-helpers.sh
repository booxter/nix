#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
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

decrypt_secret_file() {
  local host="$1"
  local out_file="$2"
  sops --decrypt "secrets/${host}.yaml" > "$out_file"
}

encrypt_secret_file() {
  local host="$1"
  local plain_file="$2"
  local tmp_file
  tmp_file="$(mktemp)"
  sops --encrypt \
    --filename-override "secrets/${host}.yaml" \
    --input-type yaml \
    --output-type yaml \
    "$plain_file" > "$tmp_file"
  mv "$tmp_file" "secrets/${host}.yaml"
}

setup_repo() {
  local repo_dir="$1"
  mkdir -p "$repo_dir/secrets/_templates" "$repo_dir/apps/_helpers" "$repo_dir/tests"
  cp "$REPO_ROOT/apps/_helpers/host-aliases.sh" "$repo_dir/apps/_helpers/"
  cp "$REPO_ROOT/apps/sops-cat.sh" "$repo_dir/apps/"
  cp "$REPO_ROOT/apps/sops-update.sh" "$repo_dir/apps/"
  cp "$REPO_ROOT/apps/sops-copy.sh" "$repo_dir/apps/"
  cp "$REPO_ROOT/apps/sops-set.sh" "$repo_dir/apps/"
  cp "$REPO_ROOT/apps/sops-ups-sync.sh" "$repo_dir/apps/"
  cp "$REPO_ROOT/apps/sops-edit.sh" "$repo_dir/apps/"
  cp "$REPO_ROOT/apps/sops-pass.sh" "$repo_dir/apps/"
  cp "$REPO_ROOT/tests/test-sops-config.sh" "$repo_dir/tests/"
  cd "$repo_dir"
  git init -q
  age-keygen -o "$repo_dir/age.txt" >/dev/null 2>&1
  export SOPS_AGE_KEY_FILE="$repo_dir/age.txt"
  local pubkey
  pubkey="$(age-keygen -y "$SOPS_AGE_KEY_FILE")"
  cat > "$repo_dir/.sops.yaml" <<EOF
keys:
  - ${pubkey}
creation_rules:
  - path_regex: secrets/.*\\.yaml\$
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
  local out="$WORKDIR/out.txt"
  local before="$WORKDIR/before.yaml"
  local after="$WORKDIR/after.yaml"
  local edited="$WORKDIR/edited.yaml"
  local copied="$WORKDIR/copied.yaml"

  setup_repo "$repo"

  cat > "$repo/secrets/_template.yaml" <<'EOF'
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

  cat > "$repo/secrets/_templates/beast.yaml" <<'EOF'
jellyfin:
  apiKey: "REPLACE_ME"
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

  log "merge default and host template keys into beast"
  run_and_capture "$out" bash "$repo/apps/sops-update.sh" beast
  assert_contains "$(cat "$out")" "Updated secret from templates:"
  decrypt_secret_file beast "$after"
  assert_eq "SECRET" "$(yq -r '.common.shared' "$after")" "beast shared value should be preserved"
  assert_eq "beast" "$(yq -r '.other.keep' "$after")" "beast unrelated data should survive update"
  assert_eq "REPLACE_ME" "$(yq -r '.attic.token' "$after")" "default template block should be added"
  assert_eq "REPLACE_ME" "$(yq -r '.flakehub.token' "$after")" "flakehub token placeholder should be added"
  assert_eq "REPLACE_ME" "$(yq -r '.users.root.hashedPassword' "$after")" "root password placeholder should be added"
  assert_eq "REPLACE_ME" "$(yq -r '.users.ihrachyshka.hashedPassword' "$after")" "user password placeholder should be added"
  assert_eq "REPLACE_ME" "$(yq -r '.jellyfin.apiKey' "$after")" "host template block should be added"
  assert_file_contains "secrets/beast.yaml" "sops:"

  log "skip re-encryption when beast is already converged"
  cp "secrets/beast.yaml" "$before"
  run_and_capture "$out" bash "$repo/apps/sops-update.sh" beast
  assert_contains "$(cat "$out")" "Secret already up to date:"
  cmp -s "$before" "secrets/beast.yaml" || fail "no-op update should not rewrite encrypted secret"

  log "force re-encrypt without changing decrypted content"
  decrypt_secret_file beast "$before"
  cp "secrets/beast.yaml" "$WORKDIR/before-force.yaml"
  run_and_capture "$out" bash "$repo/apps/sops-update.sh" --force beast
  assert_contains "$(cat "$out")" "Re-encrypted secret:"
  decrypt_secret_file beast "$after"
  cmp -s "$before" "$after" || fail "forced re-encrypt changed decrypted beast secret"
  if cmp -s "$WORKDIR/before-force.yaml" "secrets/beast.yaml"; then
    fail "forced re-encrypt should rewrite encrypted beast secret"
  fi

  log "copy a secret block without losing destination data"
  run_and_capture "$out" bash "$repo/apps/sops-copy.sh" mair prx1-lab attic
  assert_contains "$(cat "$out")" "Copied attic from mair to prx1-lab."
  decrypt_secret_file prx1-lab "$copied"
  assert_eq "NEW_TOKEN" "$(yq -r '.attic.token' "$copied")"
  assert_eq "http://nix-cache:8080" "$(yq -r '.attic.endpoint' "$copied")"
  assert_eq "dst" "$(yq -r '.other.keep' "$copied")" "destination-specific values should survive copy"
  assert_eq "LAB_UPS_PASS" "$(yq -r '.nut.users.upsslave.password' "$copied")" "destination secret values should survive copy"

  log "update a prox VM secret by short name"
  run_and_capture "$out" bash "$repo/apps/sops-update.sh" gw
  assert_contains "$(cat "$out")" "Updated secret from templates:"
  assert_contains "$(cat "$out")" "secrets/gw.yaml"
  decrypt_secret_file gw "$after"
  assert_eq "REPLACE_ME" "$(yq -r '.attic.token' "$after")" "short prox VM update should merge templates into short secret"
  assert_eq "gw" "$(yq -r '.other.keep' "$after")" "short prox VM update should preserve short secret data"

  log "copy a secret value to a different destination path"
  run_and_capture "$out" bash "$repo/apps/sops-copy.sh" \
    prx1-lab cache \
    nut/users/upsslave/password \
    nut/monitors/prx1-lab/password
  assert_contains "$(cat "$out")" "Copied nut/users/upsslave/password from prx1-lab to cache:nut/monitors/prx1-lab/password."
  decrypt_secret_file cache "$copied"
  assert_eq "LAB_UPS_PASS" "$(yq -r '.nut.monitors."prx1-lab".password' "$copied")"
  assert_eq "cache" "$(yq -r '.other.keep' "$copied")" "destination-specific values should survive copy"

  log "set a secret value from stdin without losing destination data"
  printf 'SET_FROM_STDIN\n' | run_and_capture "$out" bash "$repo/apps/sops-set.sh" cache nested/new/value
  assert_contains "$(cat "$out")" "Updated cache:nested/new/value."
  decrypt_secret_file cache "$copied"
  assert_eq "SET_FROM_STDIN" "$(yq -r '.nested.new.value' "$copied")"
  assert_eq "LAB_UPS_PASS" "$(yq -r '.nut.monitors."prx1-lab".password' "$copied")"
  assert_eq "cache" "$(yq -r '.other.keep' "$copied")" "destination-specific values should survive set"

  log "sync UPS monitor password through helper"
  cat > "$repo/ups-clients-by-server.json" <<'EOF'
{"prx1-lab":["fana"]}
EOF
  run_and_capture "$out" env UPS_CLIENTS_BY_SERVER_FILE="$repo/ups-clients-by-server.json" \
    bash "$repo/apps/sops-ups-sync.sh" prx1-lab
  assert_contains "$(cat "$out")" "Synced prx1-lab UPS password to fana."
  decrypt_secret_file fana "$copied"
  assert_eq "LAB_UPS_PASS" "$(yq -r '.nut.monitors."prx1-lab".password' "$copied")"
  assert_eq "fana" "$(yq -r '.other.keep' "$copied")" "destination-specific values should survive sync"

  log "fail cleanly when source path is missing"
  run_expect_failure "$out" bash "$repo/apps/sops-copy.sh" mair prx1-lab missing
  assert_contains "$(cat "$out")" "Path not found in source secret: missing"

  log "set a login password hash from pass without losing existing secret data"
  mkdir -p "$WORKDIR/fake-bin" "$WORKDIR/pass-store"
  cat > "$WORKDIR/fake-bin/pass" <<'EOF'
#!/bin/sh
set -eu

cmd="$1"
shift

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
    cat "$PASS_TEST_STORE/$entry"
    ;;
  *)
    echo "unexpected pass command: $cmd" >&2
    exit 2
    ;;
esac
EOF
  chmod +x "$WORKDIR/fake-bin/pass"
  run_and_capture "$out" env \
    PASS_TEST_STORE="$WORKDIR/pass-store" \
    PATH="$WORKDIR/fake-bin:$PATH" \
    bash "$repo/apps/sops-pass.sh" beast root
  assert_contains "$(cat "$out")" "Updated users/root/hashedPassword"
  assert_contains "$(cat "$out")" "Inserted host/beast/root."
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
    bash "$repo/apps/sops-pass.sh" --gen gw root
  assert_contains "$(cat "$out")" "Generated host/gw/root."
  test -f "$WORKDIR/pass-store/host/gw/root" || fail "pass entry should use short VM host name"
  decrypt_secret_file gw "$after"
  case "$(yq -r '.users.root.hashedPassword' "$after")" in
    "${sha512_prefix}"*) ;;
    *) fail "generated root password hash should use sha-512 crypt format" ;;
  esac
  assert_eq "REPLACE_ME" "$(yq -r '.users.ihrachyshka.hashedPassword' "$after")" "generated password should only update requested user"

  log "decrypt a VM secret by short name"
  run_and_capture "$out" bash "$repo/apps/sops-cat.sh" gw
  assert_contains "$(cat "$out")" "other:"
  assert_contains "$(cat "$out")" "keep: gw"

  log "update both login users with one generated password"
  run_and_capture "$out" env \
    PASS_TEST_STORE="$WORKDIR/pass-store" \
    PATH="$WORKDIR/fake-bin:$PATH" \
    bash "$repo/apps/sops-pass.sh" --gen gw both
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
  run_expect_failure "$out" bash "$repo/apps/sops-pass.sh" beast nobody
  assert_contains "$(cat "$out")" "Unsupported user: nobody"

  log "edit a secret through sops without merging template keys"
  cat > "$WORKDIR/editor.sh" <<'EOF'
#!/bin/sh
set -eu
yq -i '.attic.token = "EDITED_TOKEN" | .editorTouched = true' "$1"
EOF
  chmod +x "$WORKDIR/editor.sh"
  run_and_capture "$out" env EDITOR="$WORKDIR/editor.sh" bash "$repo/apps/sops-edit.sh" prx1-lab
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
  assert_file_contains "secrets/beast.yaml" "ENC["
  assert_file_contains "secrets/prx1-lab.yaml" "ENC["

  log "sops helper integration checks passed"
}

main "$@"
