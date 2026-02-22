#!/usr/bin/env bats

setup() {
  workdir="$BATS_TMPDIR/sops-copy"
  mkdir -p "$workdir/secrets" "$workdir/bin"
  cd "$workdir"
  git init -q

  cat > "$workdir/secrets/mair.yaml" <<'EOF'
attic:
  token: "NEW_TOKEN"
  endpoint: "http://nix-cache:8080"
other:
  keep: "src"
EOF

  cat > "$workdir/secrets/prx1-lab.yaml" <<'EOF'
attic:
  token: "OLD_TOKEN"
other:
  keep: "dst"
EOF

  cat > "$workdir/bin/sops" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == "--decrypt" ]]; then
  cat "$2"
  exit 0
fi
if [[ "$1" == "--encrypt" ]]; then
  src="${@: -1}"
  cat "$src"
  exit 0
fi
exit 1
EOF
  chmod +x "$workdir/bin/sops"

  cat > "$workdir/bin/yq" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

extract_top_level() {
  local key="$1"
  local file="$2"
  awk -v key="$key" '
    BEGIN { inside=0; found=0 }
    $0 ~ "^"key":" {
      inside=1
      found=1
      print
      next
    }
    inside==1 {
      if ($0 ~ /^[^[:space:]][^:]*:/) { exit }
      print
    }
    END {
      if (found == 0) { exit 1 }
    }
  ' "$file"
}

if [[ "$1" == "-e" ]]; then
  expr="$2"
  file="$3"
  if [[ "$expr" =~ ^\.\"([^\"]+)\"[[:space:]]+\!\=[[:space:]]+null$ ]]; then
    key="${BASH_REMATCH[1]}"
    grep -q "^${key}:" "$file"
    exit $?
  fi
  exit 1
fi

if [[ "$1" == "-y" && "$2" == "-s" ]]; then
  expr="$3"
  src="$4"
  dst="$5"
  src_key="$(printf '%s' "$expr" | sed -n 's/.*getpath(\[\"\([^\"]*\)\"\]).*/\1/p')"
  dst_key="$(printf '%s' "$expr" | sed -n 's/.*setpath(\[\"\([^\"]*\)\".*/\1/p')"
  if [[ -z "$src_key" || -z "$dst_key" || "$src_key" != "$dst_key" ]]; then
    exit 1
  fi
  tmp="$(mktemp)"
  awk -v key="$src_key" '
    BEGIN { inside=0; found=0 }
    $0 ~ "^"key":" {
      inside=1
      found=1
      print
      next
    }
    inside==1 {
      if ($0 ~ /^[^[:space:]][^:]*:/) { exit }
      print
    }
    END { if (found == 0) exit 1 }
  ' "$src" > "$tmp"

  awk -v key="$dst_key" '
    BEGIN { skip=0 }
    $0 ~ "^"key":" { skip=1; next }
    skip==1 {
      if ($0 ~ /^[^[:space:]][^:]*:/) { skip=0 }
      else { next }
    }
    { print }
  ' "$dst"
  cat "$tmp"
  rm -f "$tmp"
  exit 0
fi

if [[ "$1" == "-y" && "$2" != "--in-place" ]]; then
  expr="$2"
  file="$3"
  if [[ "$expr" =~ ^\.\"([^\"]+)\"$ ]]; then
    key="${BASH_REMATCH[1]}"
    extract_top_level "$key" "$file"
    exit $?
  fi
  exit 1
fi

exit 1
EOF
  chmod +x "$workdir/bin/yq"

  export PATH="$workdir/bin:$PATH"
}

@test "copies top-level attic block from source secret to destination secret" {
  run bash "$BATS_TEST_DIRNAME/../scripts/sops-copy.sh" mair prx1-lab attic
  [ "$status" -eq 0 ]
  [[ "$output" == *"Copied attic from mair to prx1-lab."* ]]
  grep -q 'token: "NEW_TOKEN"' "$workdir/secrets/prx1-lab.yaml"
  ! grep -q 'token: "OLD_TOKEN"' "$workdir/secrets/prx1-lab.yaml"
  grep -q 'keep: "dst"' "$workdir/secrets/prx1-lab.yaml"
}

@test "fails when key path is missing in source secret" {
  run bash "$BATS_TEST_DIRNAME/../scripts/sops-copy.sh" mair prx1-lab missing
  [ "$status" -ne 0 ]
  [[ "$output" == *"Path not found in source secret: missing"* ]]
}
