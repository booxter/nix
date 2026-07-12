#!/usr/bin/env bash
set -euo pipefail

expected_json='{
  "darwin": {
    "JGWXHWDL4X": { "isWork": true, "deployPriority": "normal" },
    "mair": { "isWork": false, "deployPriority": "normal" },
    "mmini": { "isWork": false, "deployPriority": "normal" }
  },
  "nixos": {
    "beast": { "isWork": false, "deployPriority": "normal" },
    "builder1": { "isWork": false, "deployPriority": "normal" },
    "builder2": { "isWork": false, "deployPriority": "normal" },
    "builder3": { "isWork": false, "deployPriority": "normal" },
    "cache": { "isWork": false, "deployPriority": "late" },
    "fana": { "isWork": false, "deployPriority": "normal" },
    "frame": { "isWork": false, "deployPriority": "normal" },
    "gw": { "isWork": false, "deployPriority": "normal" },
    "nv": { "isWork": true, "deployPriority": "normal" },
    "nvws": { "isWork": true, "deployPriority": "early" },
    "org": { "isWork": false, "deployPriority": "normal" },
    "pki": { "isWork": false, "deployPriority": "normal" },
    "prx1-lab": { "isWork": false, "deployPriority": "early" },
    "prx2-lab": { "isWork": false, "deployPriority": "early" },
    "prx3-lab": { "isWork": false, "deployPriority": "early" },
    "srvarr": { "isWork": false, "deployPriority": "normal" }
  }
}'

stderr_file="$(mktemp)"
if ! actual_json="$(./apps/get-hosts.sh 2>"$stderr_file")"; then
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
    "mair": { "isWork": false, "deployPriority": "normal" }
  },
  "nixos": {
    "beast": { "isWork": false, "deployPriority": "normal" },
    "nvws": { "isWork": true, "deployPriority": "early" }
  }
}'

stderr_file="$(mktemp)"
if ! filtered_json="$(./apps/get-hosts.sh mair nvws beast 2>"$stderr_file")"; then
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

# Short prox VM arguments are accepted and displayed as short names.
expected_vm_filtered='{
  "darwin": {},
  "nixos": {
    "org": { "isWork": false, "deployPriority": "normal" },
    "srvarr": { "isWork": false, "deployPriority": "normal" }
  }
}'

stderr_file="$(mktemp)"
if ! vm_filtered_json="$(./apps/get-hosts.sh org srvarr 2>"$stderr_file")"; then
  echo "get-hosts.sh with short VM args failed" >&2
  cat "$stderr_file" >&2 || true
  rm -f "$stderr_file"
  exit 1
fi
if [[ -z "$vm_filtered_json" ]]; then
  echo "get-hosts.sh with short VM args produced no output" >&2
  cat "$stderr_file" >&2 || true
  rm -f "$stderr_file"
  exit 1
fi
rm -f "$stderr_file"

vm_filtered_norm="$(printf '%s' "$vm_filtered_json" | normalize_json)"
expected_vm_filtered_norm="$(printf '%s' "$expected_vm_filtered" | normalize_json)"

if [[ "$vm_filtered_norm" != "$expected_vm_filtered_norm" ]]; then
  echo "get-hosts.sh with short VM args output mismatch" >&2
  diff -u <(printf '%s\n' "$expected_vm_filtered_norm") <(printf '%s\n' "$vm_filtered_norm") || true
  exit 1
fi

echo "get-hosts.sh with short VM args output matches expected filtered map."
