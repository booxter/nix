#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/sops-bootstrap.sh host-keygen
    - Run on the target host (as root) to create /var/lib/sops-nix/key.txt
      and print the age public key.

  scripts/sops-bootstrap.sh repo-init --host HOST (--age AGE_PUBKEY | --age-file PATH | --age-stdin)
    - Run in the repo to create secrets/HOST.yaml and .sops.yaml (patched if it exists).
EOF
}

cmd="${1:-}"
case "$cmd" in
  host-keygen)
    if ! command -v age-keygen >/dev/null 2>&1; then
      echo "age-keygen not found. Install the 'age' package on the host first."
      exit 1
    fi
    keyfile="/var/lib/sops-nix/key.txt"
    sudo mkdir -p /var/lib/sops-nix
    if [[ ! -f "$keyfile" ]]; then
      sudo age-keygen -o "$keyfile"
    fi
    if command -v rg >/dev/null 2>&1; then
      sudo rg -n "public key" "$keyfile"
    else
      sudo grep -n "public key" "$keyfile"
    fi
    ;;

  repo-init)
    shift
    host=""
    age=""
    age_file=""
    age_stdin="false"
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --host)
          host="$2"
          shift 2
          ;;
        --age)
          age="$2"
          shift 2
          ;;
        --age-file)
          age_file="$2"
          shift 2
          ;;
        --age-stdin)
          age_stdin="true"
          shift 1
          ;;
        *)
          usage
          exit 1
          ;;
      esac
    done
    if [[ -n "$age_file" && -z "$age" ]]; then
      age="$(cat "$age_file")"
    fi
    if [[ "$age_stdin" == "true" && -z "$age" ]]; then
      read -r age
    fi

    if [[ -z "$host" || -z "$age" ]]; then
      usage
      exit 1
    fi

    secrets_dir="secrets"
    secrets_file="${secrets_dir}/${host}.yaml"
    template_file="secrets/_templates/${host}.yaml"
    sops_yaml=".sops.yaml"

    mkdir -p "$secrets_dir"

    if [[ ! -f "$sops_yaml" ]]; then
      cat > "$sops_yaml" <<EOF
keys:
  - ${age}
creation_rules:
  - path_regex: secrets/${host}\\.yaml\$
    key_groups:
      - age:
          - ${age}
EOF
      echo "Created $sops_yaml."
    else
      if ! (command -v rg >/dev/null 2>&1 && rg -q "secrets/${host}\\\\.yaml" "$sops_yaml") \
        && ! grep -q "secrets/${host}\\.yaml" "$sops_yaml"; then
        if ! command -v yq >/dev/null 2>&1; then
          echo "yq not found. Install yq to patch .sops.yaml safely."
          exit 1
        fi
        if [[ "$(yq -r 'type' "$sops_yaml")" != "!!map" ]]; then
          echo ".sops.yaml must be a YAML map at top-level."
          exit 1
        fi
        if [[ "$(yq -r '.keys | type' "$sops_yaml")" != "!!seq" ]]; then
          echo ".sops.yaml must contain a top-level 'keys' sequence."
          exit 1
        fi
        if [[ "$(yq -r '.creation_rules | type' "$sops_yaml")" != "!!seq" ]]; then
          echo ".sops.yaml must contain a top-level 'creation_rules' sequence."
          exit 1
        fi
        yq -i ".keys += [\"${age}\"]" "$sops_yaml"
        yq -i ".creation_rules += [{\"path_regex\":\"secrets/${host}\\\\.yaml$\",\"key_groups\":[{\"age\":[\"${age}\"]}]}]" "$sops_yaml"
        echo "Updated $sops_yaml."
      fi
    fi

    if [[ ! -f "$secrets_file" ]]; then
      if [[ -f "$template_file" ]]; then
        sops --encrypt --age "$age" --input-type yaml --output-type yaml \
          "$template_file" > "$secrets_file"
      else
        sops --encrypt --age "$age" --input-type yaml --output-type yaml <<'EOF' > "$secrets_file"
{}
EOF
      fi
      echo "Created encrypted $secrets_file."
    else
      echo "$secrets_file already exists."
    fi
    ;;

  *)
    usage
    exit 1
    ;;
esac
