#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/sops-bootstrap.sh HOST [--user USER]
  scripts/sops-bootstrap.sh --help

This script:
  1) SSHes into HOST and generates /var/lib/sops-nix/key.txt (if missing)
  2) Reads the age public key
  3) Creates secrets/HOST.yaml encrypted with that key
  4) Creates .sops.yaml if it doesn't exist (otherwise patches it)
EOF
}

resolve_local_pubkey() {
  local key_file
  key_file="${SOPS_AGE_KEY_FILE:-${HOME}/.config/sops/age/keys.txt}"

  if [[ ! -f "$key_file" ]]; then
    echo "Local age key file not found: $key_file" >&2
    echo "Set SOPS_AGE_KEY_FILE or create ${HOME}/.config/sops/age/keys.txt first." >&2
    return 1
  fi

  if ! command -v age-keygen >/dev/null 2>&1; then
    echo "age-keygen is required locally to derive the public key." >&2
    return 1
  fi

  local local_key
  local_key="$(age-keygen -y "$key_file" 2>/dev/null | sed -n '1p' || true)"
  if [[ -z "$local_key" ]]; then
    echo "Failed to derive local age public key from: $key_file" >&2
    return 1
  fi

  printf '%s' "$local_key"
}

host=""
user="${USER:-$(whoami)}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    --user)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "Missing value for --user" >&2
        usage >&2
        exit 1
      fi
      user="$2"
      shift 2
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      if [[ -z "$host" ]]; then
        host="$1"
        shift
      else
        usage >&2
        exit 1
      fi
      ;;
  esac
done

if [[ -z "$host" ]]; then
  usage >&2
  exit 1
fi

ssh_target="${user}@${host}"
remote_output="$(mktemp)"
remote_script="/tmp/sops-bootstrap-$$.sh"
cleanup() {
  rm -f "$remote_output"
  ssh "$ssh_target" /usr/bin/env bash -lc 'rm -f -- "$1"' bash "$remote_script" >/dev/null 2>&1 || true
}
trap cleanup EXIT

if ! [ -t 0 ]; then
  echo "Error: no TTY available for sudo on ${host}. Run this command from a real terminal." >&2
  exit 1
fi

remote_payload="$(cat <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

as_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    echo "Need root privileges on remote host (login as root or install/configure sudo)." >&2
    exit 1
  fi
}

run_age_keygen() {
  if command -v age-keygen >/dev/null 2>&1; then
    as_root age-keygen -o /var/lib/sops-nix/key.txt
    return 0
  fi

  as_root nix --extra-experimental-features "nix-command flakes" shell nixpkgs#age -c age-keygen -o /var/lib/sops-nix/key.txt
}

as_root mkdir -p /var/lib/sops-nix
if ! as_root test -f /var/lib/sops-nix/key.txt; then
  run_age_keygen
fi

if command -v rg >/dev/null 2>&1; then
  key_line="$(as_root rg -n 'public key' /var/lib/sops-nix/key.txt)"
else
  key_line="$(as_root grep -n 'public key' /var/lib/sops-nix/key.txt)"
fi

pubkey="$(printf "%s\n" "$key_line" | sed -n 's/.*public key: //p' | tail -n1)"
if [ -z "$pubkey" ]; then
  echo "Failed to parse age public key from /var/lib/sops-nix/key.txt." >&2
  exit 1
fi
echo "PUBKEY:${pubkey}"
EOF
)"

printf '%s\n' "$remote_payload" | ssh "$ssh_target" /usr/bin/env bash -lc 'cat > "$1" && chmod +x "$1"' bash "$remote_script"
ssh -tt "$ssh_target" "$remote_script" | tee "$remote_output"

pubkey="$(tr -d '\r' < "$remote_output" | sed -n 's/^PUBKEY://p' | tail -n1)"

if [[ -z "$pubkey" ]]; then
  echo "Failed to read age public key from ${ssh_target}."
  exit 1
fi

local_pubkey="$(resolve_local_pubkey)"
if [[ -z "$local_pubkey" ]]; then
  echo "Failed to resolve local age public key."
  exit 1
fi

if [[ "$local_pubkey" == "$pubkey" ]]; then
  local_top_key_line=""
  local_rule_key_line=""
else
  local_top_key_line="  - ${local_pubkey}"
  local_rule_key_line="          - ${local_pubkey}"
fi

secrets_dir="secrets"
secrets_file="${secrets_dir}/${host}.yaml"
template_file="secrets/_template.yaml"
sops_yaml=".sops.yaml"

mkdir -p "$secrets_dir"

if [[ ! -f "$sops_yaml" ]]; then
  cat > "$sops_yaml" <<EOF
keys:
  - ${pubkey}
${local_top_key_line}
creation_rules:
  - path_regex: secrets/${host}\\.yaml\$
    key_groups:
      - age:
          - ${pubkey}
${local_rule_key_line}
EOF
  echo "Created $sops_yaml."
else
  if ! command -v yq >/dev/null 2>&1; then
    echo "yq not found. Install yq to patch .sops.yaml safely."
    exit 1
  fi
  if [[ "$(yq -r 'type' "$sops_yaml")" != "object" ]]; then
    echo ".sops.yaml must be a YAML map at top-level."
    exit 1
  fi
  if [[ "$(yq -r '.keys | type' "$sops_yaml")" != "array" ]]; then
    echo ".sops.yaml must contain a top-level 'keys' sequence."
    exit 1
  fi
  if [[ "$(yq -r '.creation_rules | type' "$sops_yaml")" != "array" ]]; then
    echo ".sops.yaml must contain a top-level 'creation_rules' sequence."
    exit 1
  fi

  if ! (command -v rg >/dev/null 2>&1 && rg -q "secrets/${host}\\\\.yaml" "$sops_yaml") \
    && ! grep -q "secrets/${host}\\.yaml" "$sops_yaml"; then
    yq -y --in-place ".keys += [\"${pubkey}\",\"${local_pubkey}\"] | .keys |= unique" "$sops_yaml"
    yq -y --in-place ".creation_rules += [{\"path_regex\":\"secrets/${host}\\\\.yaml$\",\"key_groups\":[{\"age\":[\"${pubkey}\",\"${local_pubkey}\"]}]}]" "$sops_yaml"
    echo "Updated $sops_yaml."
  else
    yq -y --in-place ".keys += [\"${pubkey}\",\"${local_pubkey}\"] | .keys |= unique" "$sops_yaml"
    yq -y --in-place "(.creation_rules[] | select(.path_regex == \"secrets/${host}\\\\.yaml$\") | .key_groups[]?.age) += [\"${pubkey}\",\"${local_pubkey}\"]" "$sops_yaml"
    yq -y --in-place "(.creation_rules[] | select(.path_regex == \"secrets/${host}\\\\.yaml$\") | .key_groups[]?.age) |= unique" "$sops_yaml"
    echo "Updated $sops_yaml."
  fi
fi

if [[ ! -f "$secrets_file" ]]; then
  encrypted="$(mktemp)"
  trap 'rm -f "$encrypted"' EXIT
  if [[ -f "$template_file" ]]; then
    sops --encrypt --filename-override "$secrets_file" --input-type yaml --output-type yaml \
      "$template_file" > "$encrypted"
  else
    sops --encrypt --filename-override "$secrets_file" --input-type yaml --output-type yaml <<'EOF' > "$encrypted"
{}
EOF
  fi
  if [[ ! -f "$encrypted" || ! -s "$encrypted" ]]; then
    echo "Failed to create encrypted secret for $secrets_file."
    exit 1
  fi
  mv "$encrypted" "$secrets_file"
  echo "Created encrypted $secrets_file."
else
  echo "$secrets_file already exists."
fi
