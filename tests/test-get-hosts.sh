#!/usr/bin/env bash
set -euo pipefail

expected_json='{
  "darwin": {
    "JGWXHWDL4X": true,
    "mair": false,
    "mmini": false
  },
  "nixos": {
    "frame": false,
    "nvws": true,
    "pi5": false,
    "prox-builder1vm": false,
    "prox-builder2vm": false,
    "prox-builder3vm": false,
    "prox-cachevm": false,
    "prox-jellyfinvm": false,
    "prox-nvvm": true,
    "prox-srvarrvm": false,
    "prx1-lab": false,
    "prx2-lab": false,
    "prx3-lab": false
  }
}'

stderr_file="$(mktemp)"
if ! actual_json="$(./scripts/get-hosts.sh 2>"$stderr_file")"; then
  echo "get-hosts.sh failed" >&2
  cat "$stderr_file" >&2 || true
  rm -f "$stderr_file"
  exit 1
fi
if [[ -z "$actual_json" ]]; then
  echo "get-hosts.sh produced no output" >&2
  cat "$stderr_file" >&2 || true
  rm -f "$stderr_file"
  exit 1
fi
rm -f "$stderr_file"

normalize_json() {
  python3 -c 'import json,sys; data=json.load(sys.stdin); print(json.dumps(data, sort_keys=True, separators=(",", ":")))'
}

actual_norm="$(printf '%s' "$actual_json" | normalize_json)"
expected_norm="$(printf '%s' "$expected_json" | normalize_json)"

if [[ "$actual_norm" != "$expected_norm" ]]; then
  echo "get-hosts.sh output mismatch" >&2
  diff -u <(printf '%s\n' "$expected_norm") <(printf '%s\n' "$actual_norm") || true
  exit 1
fi

echo "get-hosts.sh output matches expected map."
