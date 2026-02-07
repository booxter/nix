#!/usr/bin/env bats

setup() {
  workdir="$BATS_TMPDIR/sops-bootstrap"
  mkdir -p "$workdir"
  cd "$workdir"

  # stub yq in PATH
  mkdir -p "$workdir/bin"
  cat > "$workdir/bin/yq" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == "-r" && "$2" == "type" ]]; then
  echo "!!map"
  exit 0
fi
if [[ "$1" == "-r" && "$2" == ".keys | type" ]]; then
  echo "!!seq"
  exit 0
fi
if [[ "$1" == "-r" && "$2" == ".creation_rules | type" ]]; then
  echo "!!seq"
  exit 0
fi
if [[ "$1" == "-i" ]]; then
  # emulate append by adding simple lines for test purposes
  file="${@: -1}"
  if [[ "$2" == ".keys += [\""*"\"]" ]]; then
    echo "  - age1test" >> "$file"
  else
    cat >> "$file" <<'EOR'
  - path_regex: secrets/beast\.yaml$
    key_groups:
      - age:
          - age1test
EOR
  fi
  exit 0
fi
exit 1
EOF
  chmod +x "$workdir/bin/yq"

  # stub sops in PATH
  cat > "$workdir/bin/sops" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
out="${@: -1}"
cat <<'EOR' > "$out"
sops:
  dummy: true
EOR
EOF
  chmod +x "$workdir/bin/sops"

  export PATH="$workdir/bin:$PATH"
}

@test "repo-init creates .sops.yaml and secret when missing" {
  run bash "$BATS_TEST_DIRNAME/../scripts/sops-bootstrap.sh" repo-init --host beast --age age1test
  [ "$status" -eq 0 ]
  [ -f .sops.yaml ]
  [ -f secrets/beast.yaml ]
  rg -q "^keys:" .sops.yaml
  rg -q "^- age1test$" .sops.yaml
  rg -q "path_regex: secrets/beast\\\\.yaml\\$" .sops.yaml
}

@test "repo-init patches existing .sops.yaml" {
  cat > .sops.yaml <<'EOF'
keys:
  - age1existing
creation_rules:
  - path_regex: secrets/old\.yaml$
    key_groups:
      - age:
          - age1existing
EOF
  run bash "$BATS_TEST_DIRNAME/../scripts/sops-bootstrap.sh" repo-init --host beast --age age1test
  [ "$status" -eq 0 ]
  rg -q "secrets/beast\\\\.yaml\\$" .sops.yaml
  rg -q "age1test" .sops.yaml
}
