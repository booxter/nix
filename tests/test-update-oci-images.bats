#!/usr/bin/env bats

setup() {
  export TEST_BIN="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "$TEST_BIN"
  export PATH="${TEST_BIN}:${PATH}"

  {
    printf '#!%s\n' "$(command -v bash)"
    cat <<'EOF'
set -euo pipefail

if [[ "$1" != "list-tags" || "$2" != "docker://docker.io/example/romm" ]]; then
  echo "unexpected skopeo args: $*" >&2
  exit 1
fi

cat <<'JSON'
{
  "Tags": [
    "latest",
    "4.9.1",
    "4.10.0",
    "4.10.0-beta.1",
    "5"
  ]
}
JSON
EOF
  } > "${TEST_BIN}/skopeo"
  chmod +x "${TEST_BIN}/skopeo"
}

@test "updates selected OCI image tag from registry tags" {
  pins_file="${BATS_TEST_TMPDIR}/oci-images.json"
  summary_file="${BATS_TEST_TMPDIR}/summary.md"
  cat > "$pins_file" <<'JSON'
{
  "other": {
    "image": "docker.io/example/other",
    "tag": "1.0.0",
    "tagRegex": "^[0-9]+\\.[0-9]+\\.[0-9]+$"
  },
  "romm": {
    "image": "docker.io/example/romm",
    "tag": "4.9.1",
    "tagRegex": "^[0-9]+\\.[0-9]+\\.[0-9]+$",
    "changelog": "https://example.invalid/releases/{tag}"
  }
}
JSON

  run bash apps/package-updates/update-oci-images.sh \
    --pins-file "$pins_file" \
    --summary-file "$summary_file" \
    --target romm

  if [ "$status" -ne 0 ]; then
    printf 'status: %s\n%s\n' "$status" "$output" >&3
    return 1
  fi
  [ "$(jq -r '.romm.tag' "$pins_file")" = "4.10.0" ]
  [ "$(jq -r '.other.tag' "$pins_file")" = "1.0.0" ]
  grep -F '| `romm` | `docker.io/example/romm` | `4.9.1 -> 4.10.0` | [link](https://example.invalid/releases/4.10.0) |' "$summary_file"
}

@test "lists OCI image targets" {
  pins_file="${BATS_TEST_TMPDIR}/oci-images.json"
  cat > "$pins_file" <<'JSON'
{
  "romm": {
    "image": "docker.io/example/romm",
    "tag": "4.9.1"
  }
}
JSON

  run bash apps/package-updates/update-oci-images.sh \
    --pins-file "$pins_file" \
    --list-targets

  [ "$status" -eq 0 ]
  [ "$output" = $'romm\tdocker.io/example/romm:4.9.1' ]
}
