#!/usr/bin/env bash

enable_strict_mode() {
  set -euo pipefail
}

resolve_yq() {
  if command -v yq >/dev/null 2>&1; then
    command -v yq
    return 0
  fi
  if ! command -v nix >/dev/null 2>&1; then
    echo "yq not found and nix is unavailable to build it." >&2
    return 1
  fi
  local yq_store
  yq_store="$(nix build nixpkgs#yq-go --no-link --print-out-paths)"
  echo "${yq_store}/bin/yq"
}

YQ_BIN="$(resolve_yq)"

yq() {
  "$YQ_BIN" "$@"
}

has_secrets() {
  compgen -G "secrets/*/*.yaml" >/dev/null 2>&1
}

assert_sops_yaml_present() {
  if has_secrets && [[ ! -f .sops.yaml ]]; then
    echo "secrets/*/*.yaml present but .sops.yaml is missing."
    return 1
  fi
}

check_sops_yaml_structure() {
  if [[ -f .sops.yaml ]]; then
    if [[ "$(yq -r 'type' .sops.yaml)" != "!!map" ]]; then
      echo ".sops.yaml must be a YAML map at top-level."
      return 1
    fi
    if [[ "$(yq -r '.keys | type' .sops.yaml)" != "!!seq" ]]; then
      echo ".sops.yaml must contain a top-level 'keys' sequence."
      return 1
    fi
    if [[ "$(yq -r '.keys | length' .sops.yaml)" == "0" ]]; then
      echo ".sops.yaml 'keys' sequence must not be empty."
      return 1
    fi
    if [[ "$(yq -r '.creation_rules | type' .sops.yaml)" != "!!seq" ]]; then
      echo ".sops.yaml must contain a top-level 'creation_rules' sequence."
      return 1
    fi
    if [[ "$(yq -r '.creation_rules | length' .sops.yaml)" == "0" ]]; then
      echo ".sops.yaml 'creation_rules' sequence must not be empty."
      return 1
    fi
  fi
}

check_secrets_encrypted() {
  if has_secrets; then
    for f in secrets/*/*.yaml; do
      if [[ "$(basename -- "$f")" == "_template.yaml" ]]; then
        continue
      fi
      if ! yq -e '.sops' "$f" >/dev/null; then
        echo "$f is missing a 'sops' block (not encrypted?)."
        return 1
      fi
    done
  fi
}

check_domain_isolation() {
  local main_recipients
  local work_recipients
  local overlap

  main_recipients="$(
    yq -o=json '.creation_rules' .sops.yaml \
      | jq -r '.[] | select(.path_regex | startswith("secrets/main/")) | .key_groups[]?.age[]' \
      | sort -u
  )"
  work_recipients="$(
    yq -o=json '.creation_rules' .sops.yaml \
      | jq -r '.[] | select(.path_regex | startswith("secrets/work/")) | .key_groups[]?.age[]' \
      | sort -u
  )"
  if [[ -z "$main_recipients" || -z "$work_recipients" ]]; then
    return
  fi

  overlap="$(comm -12 <(printf '%s\n' "$main_recipients") <(printf '%s\n' "$work_recipients"))"
  if [[ -n "$overlap" ]]; then
    echo "Secret domains main and work share age recipients:" >&2
    printf '%s\n' "$overlap" >&2
    return 1
  fi
}

main() {
  enable_strict_mode
  assert_sops_yaml_present || return 1
  check_sops_yaml_structure || return 1
  check_secrets_encrypted || return 1
  check_domain_isolation || return 1
  echo "sops config check passed."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main
fi
