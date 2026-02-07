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
            echo "!!map"
          else
            echo "!!str"
          fi
          ;;
        ".keys | type")
          if grep -q '^keys:' "$file"; then echo "!!seq"; else echo "!!null"; fi
          ;;
        ".keys | length")
          if grep -q '^keys:' "$file"; then echo "1"; else echo "0"; fi
          ;;
        ".creation_rules | type")
          if grep -q '^creation_rules:' "$file"; then echo "!!seq"; else echo "!!null"; fi
          ;;
        ".creation_rules | length")
          if grep -q '^creation_rules:' "$file"; then echo "1"; else echo "0"; fi
          ;;
        *)
          echo "!!null"
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

@test "sops-merge-template merges missing keys from template" {
  workdir="$BATS_TMPDIR/sops-merge"
  mkdir -p "$workdir/secrets/_templates"
  cat > "$workdir/secrets/_templates/beast.yaml" <<'EOF'
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

  sops() {
    if [[ "$1" == "--decrypt" ]]; then
      cat "$2"
      return 0
    fi
    if [[ "$1" == "--encrypt" && "$2" == "--in-place" ]]; then
      local target="${@: -1}"
      cat - > "$target"
      return 0
    fi
    return 1
  }

  yq() {
    if [[ "$1" == "-s" ]]; then
      # Minimal merge: keep secret value if present, otherwise take template.
      local file_a="$3"
      local file_b="$4"
      if rg -q 'gmail_password: "SECRET"' "$file_b"; then
        printf '%s\n' 'msmtp:' '  gmail_password: "SECRET"' 'other:' '  key: "TEMPLATE"'
      else
        cat "$file_a"
      fi
      return 0
    fi
    return 1
  }

  source "$BATS_TEST_DIRNAME/../scripts/sops-merge-template.sh"
  run main --host beast
  [ "$status" -eq 0 ]
  grep -q 'gmail_password: "SECRET"' "$workdir/secrets/beast.yaml"
  grep -q 'key: "TEMPLATE"' "$workdir/secrets/beast.yaml"
  ! grep -q 'REPLACE_ME' "$workdir/secrets/beast.yaml"
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

@test "passes with template stored under secrets/_templates" {
  workdir="$BATS_TMPDIR/sops-template"
  mkdir -p "$workdir/secrets/_templates"
  cat > "$workdir/secrets/_templates/beast.yaml" <<'EOF'
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
