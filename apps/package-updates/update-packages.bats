#!/usr/bin/env bats

setup() {
  export TEST_BIN="${BATS_TEST_TMPDIR}/bin"
  export TEST_STATE="${BATS_TEST_TMPDIR}/updated"
  mkdir -p "$TEST_BIN"
  export PATH="${TEST_BIN}:${PATH}"

  {
    printf '#!%s\n' "$(command -v bash)"
    cat <<'EOF'
set -euo pipefail

if [[ "$1" == "build" ]]; then
  exit 1
fi

if [[ "$1" != "eval" ]]; then
  echo "unexpected nix args: $*" >&2
  exit 1
fi

expr="${@: -1}"
updated=0
if [[ -f "${TEST_STATE}" ]]; then
  updated=1
fi

case "$expr" in
  *".version")
    if [[ "$updated" -eq 1 ]]; then
      printf '%s\n' "1.1.0"
    else
      printf '%s\n' "1.0.0"
    fi
    ;;
  *".meta.changelog")
    if [[ "$updated" -eq 1 ]]; then
      printf '%s\n' "https://github.com/example/demo/releases/tag/v1.1.0"
    else
      printf '%s\n' "https://github.com/example/demo/releases/tag/v1.0.0"
    fi
    ;;
  *".meta.homepage")
    printf '%s\n' "https://github.com/example/demo"
    ;;
  *".src.rev")
    if [[ "$updated" -eq 1 ]]; then
      printf '%s\n' "refs/tags/v1.1.0"
    else
      printf '%s\n' "refs/tags/v1.0.0"
    fi
    ;;
  *".passthru.updateScript")
    printf '%s\n' "null"
    ;;
  *)
    echo "unexpected nix eval expr: $expr" >&2
    exit 1
    ;;
esac
EOF
  } > "${TEST_BIN}/nix"
  chmod +x "${TEST_BIN}/nix"

  {
    printf '#!%s\n' "$(command -v bash)"
    cat <<'EOF'
set -euo pipefail
touch "${TEST_STATE}"
EOF
  } > "${TEST_BIN}/nix-update"
  chmod +x "${TEST_BIN}/nix-update"
}

@test "package update summary includes github compare link from source revs" {
  targets_file="${BATS_TEST_TMPDIR}/targets.json"
  summary_file="${BATS_TEST_TMPDIR}/summary.md"
  cat > "$targets_file" <<'JSON'
{
  "targets": [
    {
      "attr": "demo",
      "system": "x86_64-linux"
    }
  ]
}
JSON

  run bash apps/package-updates/update-packages.sh \
    --targets-file "$targets_file" \
    --summary-file "$summary_file" \
    --target demo

  if [ "$status" -ne 0 ]; then
    printf 'status: %s\n%s\n' "$status" "$output" >&3
    return 1
  fi

  grep -F '| `demo` | `1.0.0 -> 1.1.0` | [link](https://github.com/example/demo/releases/tag/v1.1.0) | [compare](https://github.com/example/demo/compare/v1.0.0...v1.1.0) |' "$summary_file"
}
