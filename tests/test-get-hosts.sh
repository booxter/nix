#!/usr/bin/env bash
set -euo pipefail

expected_json='{
  "darwin": {
    "JGWXHWDL4X": true,
    "mair": false,
    "mmini": false
  },
  "nixos": {
    "beast": false,
    "builder1": false,
    "builder2": false,
    "builder3": false,
    "cache": false,
    "fana": false,
    "frame": false,
    "gw": false,
    "nv": true,
    "nvws": true,
    "org": false,
    "pki": false,
    "prx1-lab": false,
    "prx2-lab": false,
    "prx3-lab": false,
    "srvarr": false
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

# Test with specific host arguments
expected_filtered='{
  "darwin": {
    "mair": false
  },
  "nixos": {
    "beast": false,
    "nvws": true
  }
}'

stderr_file="$(mktemp)"
if ! filtered_json="$(./scripts/get-hosts.sh mair nvws beast 2>"$stderr_file")"; then
  echo "get-hosts.sh with args failed" >&2
  cat "$stderr_file" >&2 || true
  rm -f "$stderr_file"
  exit 1
fi
if [[ -z "$filtered_json" ]]; then
  echo "get-hosts.sh with args produced no output" >&2
  cat "$stderr_file" >&2 || true
  rm -f "$stderr_file"
  exit 1
fi
rm -f "$stderr_file"

filtered_norm="$(printf '%s' "$filtered_json" | normalize_json)"
expected_filtered_norm="$(printf '%s' "$expected_filtered" | normalize_json)"

if [[ "$filtered_norm" != "$expected_filtered_norm" ]]; then
  echo "get-hosts.sh with args output mismatch" >&2
  diff -u <(printf '%s\n' "$expected_filtered_norm") <(printf '%s\n' "$filtered_norm") || true
  exit 1
fi

echo "get-hosts.sh with args output matches expected filtered map."

# Canonical prox VM arguments are still accepted but displayed as short names.
expected_canonical_filtered='{
  "darwin": {},
  "nixos": {
    "org": false,
    "srvarr": false
  }
}'

stderr_file="$(mktemp)"
if ! canonical_filtered_json="$(./scripts/get-hosts.sh prox-orgvm srvarr 2>"$stderr_file")"; then
  echo "get-hosts.sh with canonical VM args failed" >&2
  cat "$stderr_file" >&2 || true
  rm -f "$stderr_file"
  exit 1
fi
if [[ -z "$canonical_filtered_json" ]]; then
  echo "get-hosts.sh with canonical VM args produced no output" >&2
  cat "$stderr_file" >&2 || true
  rm -f "$stderr_file"
  exit 1
fi
rm -f "$stderr_file"

canonical_filtered_norm="$(printf '%s' "$canonical_filtered_json" | normalize_json)"
expected_canonical_filtered_norm="$(printf '%s' "$expected_canonical_filtered" | normalize_json)"

if [[ "$canonical_filtered_norm" != "$expected_canonical_filtered_norm" ]]; then
  echo "get-hosts.sh with canonical VM args output mismatch" >&2
  diff -u <(printf '%s\n' "$expected_canonical_filtered_norm") <(printf '%s\n' "$canonical_filtered_norm") || true
  exit 1
fi

echo "get-hosts.sh with canonical VM args output matches expected filtered map."
