#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/sops-bootstrap-remote.sh --host HOST [--user USER]

This script:
  1) SSHes into HOST and generates /var/lib/sops-nix/key.txt (if missing)
  2) Reads the age public key
  3) Creates secrets/HOST.yaml encrypted with that key
  4) Creates .sops.yaml if it doesn't exist (otherwise patches it)
EOF
}

host=""
user="${USER:-$(whoami)}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)
      host="$2"
      shift 2
      ;;
    --user)
      user="$2"
      shift 2
      ;;
    *)
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$host" ]]; then
  usage
  exit 1
fi

ssh_target="${user}@${host}"
pubkey="$(
  ssh "$ssh_target" "command -v age-keygen >/dev/null 2>&1 || \
      { echo 'age-keygen not found on host. Install the age package.'; exit 1; }; \
    sudo mkdir -p /var/lib/sops-nix && \
    if [[ ! -f /var/lib/sops-nix/key.txt ]]; then sudo age-keygen -o /var/lib/sops-nix/key.txt; fi && \
    sudo rg -n 'public key' /var/lib/sops-nix/key.txt || sudo grep -n 'public key' /var/lib/sops-nix/key.txt" \
    | sed -n 's/.*public key: //p'
)"

if [[ -z "$pubkey" ]]; then
  echo "Failed to read age public key from ${ssh_target}."
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
  - ${pubkey}
creation_rules:
  - path_regex: secrets/${host}\\.yaml\$
    key_groups:
      - age:
          - ${pubkey}
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
    yq -i ".keys += [\"${pubkey}\"]" "$sops_yaml"
    yq -i ".creation_rules += [{\"path_regex\":\"secrets/${host}\\\\.yaml$\",\"key_groups\":[{\"age\":[\"${pubkey}\"]}]}]" "$sops_yaml"
    echo "Updated $sops_yaml."
  fi
fi

if [[ ! -f "$secrets_file" ]]; then
  if [[ -f "$template_file" ]]; then
    sops --encrypt --age "$pubkey" --input-type yaml --output-type yaml \
      "$template_file" > "$secrets_file"
  else
    sops --encrypt --age "$pubkey" --input-type yaml --output-type yaml <<'EOF' > "$secrets_file"
{}
EOF
  fi
  echo "Created encrypted $secrets_file."
else
  echo "$secrets_file already exists."
fi
