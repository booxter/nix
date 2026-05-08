#!/usr/bin/env bats

load_test_script() {
  source "$BATS_TEST_DIRNAME/../tests/test-sops-config.sh"

  yq() {
    local flag="$1"
    shift
    if [[ "$flag" == "-r" ]]; then
      local query="$1"
      local file="$2"
      case "$query" in
        "type")
          if grep -q '^keys:' "$file" || grep -q '^creation_rules:' "$file"; then
            echo "object"
          else
            echo "string"
          fi
          ;;
        ".keys | type")
          if grep -q '^keys:' "$file"; then echo "array"; else echo "null"; fi
          ;;
        ".keys | length")
          if grep -q '^keys:' "$file"; then echo "1"; else echo "0"; fi
          ;;
        ".creation_rules | type")
          if grep -q '^creation_rules:' "$file"; then echo "array"; else echo "null"; fi
          ;;
        ".creation_rules | length")
          if grep -q '^creation_rules:' "$file"; then echo "1"; else echo "0"; fi
          ;;
        *)
          echo "null"
          ;;
      esac
      return 0
    fi
    if [[ "$flag" == "-e" ]]; then
      local query="$1"
      local file="$2"
      if [[ "$query" == ".sops" ]]; then
        grep -q '^sops:' "$file"
        return $?
      fi
    fi
    return 1
  }
}

@test "sops-update merges missing keys from default template" {
  workdir="$BATS_TMPDIR/sops-merge"
  mkdir -p "$workdir/secrets"
  cat > "$workdir/secrets/_template.yaml" <<'EOF'
msmtp:
  gmail_password: "REPLACE_ME"
other:
  key: "TEMPLATE"
EOF
  cat > "$workdir/secrets/beast.yaml" <<'EOF'
msmtp:
  gmail_password: "SECRET"
sops:
  dummy: true
EOF
  cd "$workdir"
  git init -q

  sops() {
    if [[ "$1" == "--decrypt" ]]; then
      cat "$2"
      return 0
    fi
    if [[ "$1" == "--encrypt" ]]; then
      local source_file="${@: -1}"
      yq -y '.' "$source_file"
      printf '%s\n' 'sops:' '  dummy: true'
      return 0
    fi
    return 1
  }

  source "$BATS_TEST_DIRNAME/../scripts/sops-update.sh"
  run main beast
  [ "$status" -eq 0 ]
  grep -q 'gmail_password: SECRET' "$workdir/secrets/beast.yaml"
  grep -q 'key: TEMPLATE' "$workdir/secrets/beast.yaml"
  ! grep -q 'REPLACE_ME' "$workdir/secrets/beast.yaml"
}

@test "sops-update also merges missing keys from host template" {
  workdir="$BATS_TMPDIR/sops-merge-host-template"
  mkdir -p "$workdir/secrets/_templates"
  cat > "$workdir/secrets/_template.yaml" <<'EOF'
common:
  shared: "TEMPLATE"
EOF
  cat > "$workdir/secrets/_templates/beast.yaml" <<'EOF'
jellyfin:
  apiKey: "REPLACE_ME"
EOF
  cat > "$workdir/secrets/beast.yaml" <<'EOF'
common:
  shared: "SECRET"
sops:
  dummy: true
EOF
  cd "$workdir"
  git init -q

  sops() {
    if [[ "$1" == "--decrypt" ]]; then
      cat "$2"
      return 0
    fi
    if [[ "$1" == "--encrypt" ]]; then
      local source_file="${@: -1}"
      yq -y '.' "$source_file"
      printf '%s\n' 'sops:' '  dummy: true'
      return 0
    fi
    return 1
  }

  source "$BATS_TEST_DIRNAME/../scripts/sops-update.sh"
  run main beast
  [ "$status" -eq 0 ]
  grep -q 'shared: SECRET' "$workdir/secrets/beast.yaml"
  grep -q 'apiKey: REPLACE_ME' "$workdir/secrets/beast.yaml"
}

@test "sops-update skips re-encryption when secret is already up to date" {
  workdir="$BATS_TMPDIR/sops-no-op"
  mkdir -p "$workdir/secrets"
  cat > "$workdir/secrets/_template.yaml" <<'EOF'
a:
  y: "SECRET"
EOF
  cat > "$workdir/secrets/beast.yaml" <<'EOF'
a:
  y: "SECRET"
sops:
  dummy: true
EOF
  cd "$workdir"
  git init -q
  encrypt_called="$workdir/encrypt-called"

  sops() {
    if [[ "$1" == "--decrypt" ]]; then
      cat "$2"
      return 0
    fi
    if [[ "$1" == "--encrypt" ]]; then
      : > "$encrypt_called"
      local source_file="${@: -1}"
      yq -y '.' "$source_file"
      printf '%s\n' 'sops:' '  dummy: true'
      return 0
    fi
    return 1
  }

  source "$BATS_TEST_DIRNAME/../scripts/sops-update.sh"
  run main beast
  [ "$status" -eq 0 ]
  [[ "$output" == *"Secret already up to date:"* ]]
  [ ! -f "$encrypt_called" ]
}

@test "sops-update --force re-encrypts when secret content is unchanged" {
  workdir="$BATS_TMPDIR/sops-force"
  mkdir -p "$workdir/secrets"
  cat > "$workdir/secrets/_template.yaml" <<'EOF'
a:
  y: "SECRET"
EOF
  cat > "$workdir/secrets/beast.yaml" <<'EOF'
a:
  y: "SECRET"
sops:
  dummy: true
EOF
  cd "$workdir"
  git init -q
  encrypt_called="$workdir/encrypt-called"

  sops() {
    if [[ "$1" == "--decrypt" ]]; then
      cat "$2"
      return 0
    fi
    if [[ "$1" == "--encrypt" ]]; then
      : > "$encrypt_called"
      local source_file="${@: -1}"
      yq -y '.' "$source_file"
      printf '%s\n' 'sops:' '  dummy: true'
      return 0
    fi
    return 1
  }

  source "$BATS_TEST_DIRNAME/../scripts/sops-update.sh"
  run main --force beast
  [ "$status" -eq 0 ]
  [[ "$output" == *"Re-encrypted secret:"* ]]
  [ -f "$encrypt_called" ]
}

@test "sops-update sorts keys and keeps sops last" {
  workdir="$BATS_TMPDIR/sops-sort-order"
  mkdir -p "$workdir/secrets"
  cat > "$workdir/secrets/_template.yaml" <<'EOF'
b:
  z: "TEMPLATE"
a:
  y: "TEMPLATE"
EOF
  cat > "$workdir/secrets/beast.yaml" <<'EOF'
sops:
  dummy: true
c:
  x: "SECRET"
EOF
  cd "$workdir"
  git init -q

  sops() {
    if [[ "$1" == "--decrypt" ]]; then
      cat "$2"
      return 0
    fi
    if [[ "$1" == "--encrypt" ]]; then
      local source_file="${@: -1}"
      yq -y '.' "$source_file"
      printf '%s\n' 'sops:' '  dummy: true'
      return 0
    fi
    return 1
  }

  source "$BATS_TEST_DIRNAME/../scripts/sops-update.sh"
  run main beast
  [ "$status" -eq 0 ]
  mapfile -t keys < <(grep -E '^[a-z][a-zA-Z0-9_-]*:' "$workdir/secrets/beast.yaml" | cut -d: -f1)
  [ "${keys[0]}" = "a" ]
  [ "${keys[1]}" = "b" ]
  [ "${keys[2]}" = "c" ]
  [ "${keys[3]}" = "sops" ]
}

@test "sops-update avoids yq eval/eval-all and uses portable yq+jq flow" {
  workdir="$BATS_TMPDIR/sops-yq-portable"
  mkdir -p "$workdir/secrets/_templates"
  cat > "$workdir/secrets/_template.yaml" <<'EOF'
common:
  shared: "TEMPLATE"
EOF
  cat > "$workdir/secrets/_templates/beast.yaml" <<'EOF'
jellyfin:
  apiKey: "REPLACE_ME"
EOF
  cat > "$workdir/secrets/beast.yaml" <<'EOF'
common:
  shared: "SECRET"
sops:
  dummy: true
EOF
  cd "$workdir"
  git init -q
  mkdir -p "$workdir/bin"
  bash_path="$(command -v bash)"

  sops() {
    if [[ "$1" == "--decrypt" ]]; then
      cat "$2"
      return 0
    fi
    if [[ "$1" == "--encrypt" ]]; then
      local source_file="${@: -1}"
      yq -y '.' "$source_file"
      printf '%s\n' 'sops:' '  dummy: true'
      return 0
    fi
    return 1
  }

  {
    printf '#!%s\n' "$bash_path"
    cat <<'EOF'
set -euo pipefail
if [[ "$1" == "eval" || "$1" == "eval-all" ]]; then
  echo "unexpected yq v4 invocation: $*" >&2
  exit 1
fi
if [[ "$1" == "-y" && "$2" == "-s" ]]; then
  file_a="$4"
  file_b="$5"
  if [[ "$file_a" == *"/_template.yaml" && "$file_b" == *"/_templates/beast.yaml" ]]; then
    printf '%s\n' 'common:' '  shared: "TEMPLATE"' 'jellyfin:' '  apiKey: "REPLACE_ME"'
    exit 0
  fi
  printf '%s\n' 'common:' '  shared: "SECRET"' 'jellyfin:' '  apiKey: "REPLACE_ME"' 'sops:' '  dummy: true'
  exit 0
fi
if [[ "$1" == "-y" && "$2" == "." && -f "$3" ]]; then
  if grep -q 'apiKey' "$3"; then
    printf '%s\n' 'common:' '  shared: SECRET' 'jellyfin:' '  apiKey: REPLACE_ME'
  else
    printf '%s\n' 'common:' '  shared: SECRET'
  fi
  exit 0
fi
if [[ "$1" == "." && -f "$2" ]]; then
  if grep -q 'apiKey: "REPLACE_ME"' "$2"; then
    printf '%s\n' '{"common":{"shared":"SECRET"},"jellyfin":{"apiKey":"REPLACE_ME"}}'
  else
    printf '%s\n' '{"common":{"shared":"SECRET"}}'
  fi
  exit 0
fi
exit 1
EOF
  } > "$workdir/bin/yq"
  chmod +x "$workdir/bin/yq"

  {
    printf '#!%s\n' "$bash_path"
    cat <<'EOF'
set -euo pipefail
cat
EOF
  } > "$workdir/bin/jq"
  chmod +x "$workdir/bin/jq"

  export PATH="$workdir/bin:$PATH"

  source "$BATS_TEST_DIRNAME/../scripts/sops-update.sh"
  run main beast
  [ "$status" -eq 0 ]
  grep -q 'shared: SECRET' "$workdir/secrets/beast.yaml"
  grep -q 'apiKey: REPLACE_ME' "$workdir/secrets/beast.yaml"
}

@test "fails when secrets exist but .sops.yaml missing" {
  workdir="$BATS_TMPDIR/sops-missing"
  mkdir -p "$workdir/secrets"
  printf 'sops:\n' > "$workdir/secrets/beast.yaml"
  cd "$workdir"
  load_test_script
  run main
  [ "$status" -ne 0 ]
  [[ "$output" == *".sops.yaml is missing"* ]]
}

@test "passes with valid .sops.yaml and encrypted secrets" {
  workdir="$BATS_TMPDIR/sops-ok"
  mkdir -p "$workdir/secrets"
  cat > "$workdir/.sops.yaml" <<'EOF'
keys:
  - age1example
creation_rules:
  - path_regex: secrets/beast\.yaml$
    key_groups:
      - age:
          - age1example
EOF
  printf 'sops:\n' > "$workdir/secrets/beast.yaml"
  cd "$workdir"
  load_test_script
  run main
  [ "$status" -eq 0 ]
  [[ "$output" == *"sops config check passed."* ]]
}

@test "passes with default template stored under secrets/_template.yaml" {
  workdir="$BATS_TMPDIR/sops-template"
  mkdir -p "$workdir/secrets"
  cat > "$workdir/secrets/_template.yaml" <<'EOF'
msmtp:
  gmail_password: "REPLACE_ME"
EOF
  cat > "$workdir/.sops.yaml" <<'EOF'
keys:
  - age1example
creation_rules:
  - path_regex: secrets/beast\.yaml$
    key_groups:
      - age:
          - age1example
EOF
  printf 'sops:\n' > "$workdir/secrets/beast.yaml"
  cd "$workdir"
  load_test_script
  run main
  [ "$status" -eq 0 ]
  [[ "$output" == *"sops config check passed."* ]]
}

@test "fails when .sops.yaml keys section missing" {
  workdir="$BATS_TMPDIR/sops-bad"
  mkdir -p "$workdir/secrets"
  cat > "$workdir/.sops.yaml" <<'EOF'
creation_rules:
  - path_regex: secrets/beast\.yaml$
    key_groups:
      - age:
          - age1example
EOF
  printf 'sops:\n' > "$workdir/secrets/beast.yaml"
  cd "$workdir"
  load_test_script
  run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"top-level 'keys' sequence"* ]]
}
