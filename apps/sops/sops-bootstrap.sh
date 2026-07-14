#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  apps/sops/sops-bootstrap.sh [--domain DOMAIN] [--local] HOST [--user USER]
  apps/sops/sops-bootstrap.sh --help

This script:
  1) Generates /var/lib/sops-nix/key.txt locally or over SSH (if missing)
  2) Reads the age public key
  3) Creates secrets/DOMAIN/HOST.yaml encrypted with that key
  4) Creates .sops.yaml if it doesn't exist (otherwise patches it)
EOF
}

resolve_local_pubkey() {
  local key_file
  local recipient_helper
  key_file="${SOPS_AGE_KEY_FILE:-${HOME}/.config/sops/age/keys.txt}"
  recipient_helper="${SOPS_AGE_RECIPIENT_HELPER:-$(dirname -- "$0")/age-recipient.sh}"

  if [[ ! -f "$key_file" ]]; then
    echo "Local age key file not found: $key_file" >&2
    echo "Set SOPS_AGE_KEY_FILE or create ${HOME}/.config/sops/age/keys.txt first." >&2
    return 1
  fi

  if [[ ! -x "$recipient_helper" ]]; then
    echo "Age recipient helper is not executable: $recipient_helper" >&2
    return 1
  fi

  local local_key
  if ! local_key="$("$recipient_helper" "$key_file" | sed -n '1p')"; then
    echo "Failed to derive local age public key from: $key_file" >&2
    return 1
  fi
  if [[ -z "$local_key" ]]; then
    echo "Failed to derive local age public key from: $key_file" >&2
    return 1
  fi

  printf '%s' "$local_key"
}

resolve_control_plane_pubkey() {
  local sops_yaml="$1"
  local local_pubkey="$2"
  local domain="$3"
  local control_host="pki"

  if [[ ! -f "$sops_yaml" ]]; then
    return 0
  fi

  if ! command -v yq >/dev/null 2>&1; then
    return 0
  fi

  yq -r ".creation_rules[] | select(.path_regex == \"secrets/${domain}/${control_host}\\\\.yaml$\") | .key_groups[]?.age[]" "$sops_yaml" \
    | awk -v local_key="$local_pubkey" '$0 != local_key { print; exit }'
}

as_root_local() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

local_runtime_pubkey() {
  local key_file="/var/lib/sops-nix/key.txt"
  local age_keygen
  age_keygen="$(command -v age-keygen)"

  as_root_local mkdir -p "$(dirname -- "$key_file")"
  if ! as_root_local test -f "$key_file"; then
    as_root_local "$age_keygen" -o "$key_file"
    as_root_local chmod 0400 "$key_file"
  fi
  as_root_local sed -n 's/^# public key: //p' "$key_file" | tail -n1
}

remote_runtime_pubkey() {
  local ssh_target="$1"
  local remote_output
  local remote_script
  local remote_script_q
  local remote_payload
  local pubkey

  remote_output="$(mktemp)"
  remote_script="/tmp/sops-bootstrap-$$.sh"
  remote_script_q="$(printf '%q' "$remote_script")"
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
  else
    as_root nix --extra-experimental-features "nix-command flakes" shell nixpkgs#age -c age-keygen -o /var/lib/sops-nix/key.txt
  fi
}

as_root mkdir -p /var/lib/sops-nix
if ! as_root test -f /var/lib/sops-nix/key.txt; then
  run_age_keygen
  as_root chmod 0400 /var/lib/sops-nix/key.txt
fi

pubkey="$(as_root sed -n 's/^# public key: //p' /var/lib/sops-nix/key.txt | tail -n1)"
if [ -z "$pubkey" ]; then
  echo "Failed to parse age public key from /var/lib/sops-nix/key.txt." >&2
  exit 1
fi
echo "PUBKEY:${pubkey}"
EOF
)"

  # shellcheck disable=SC2029
  printf '%s\n' "$remote_payload" | ssh "$ssh_target" "cat > ${remote_script_q} && chmod +x ${remote_script_q}"
  ssh -tt "$ssh_target" "bash ${remote_script_q}" | tee "$remote_output" >&2
  pubkey="$(tr -d '\r' < "$remote_output" | sed -n 's/^PUBKEY://p' | tail -n1)"
  # shellcheck disable=SC2029
  ssh "$ssh_target" "rm -f -- ${remote_script_q}" >/dev/null 2>&1 || true
  rm -f "$remote_output"
  printf '%s\n' "$pubkey"
}

ensure_work_operator_identity() {
  local key_file="$1"
  local key_dir
  key_dir="$(dirname -- "$key_file")"

  if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "The work operator identity must be initialized on macOS with Secure Enclave support." >&2
    return 1
  fi
  if [[ ! -f "$key_file" ]]; then
    mkdir -p "$key_dir"
    chmod 0700 "$key_dir"
    umask 077
    age-plugin-se keygen --access-control current-biometry -o "$key_file"
  fi
  chmod 0600 "$key_file"
}

host=""
user="${USER:-$(whoami)}"
domain=""
local_mode=0

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
    --domain)
      domain="${2:?Missing value for --domain}"
      shift 2
      ;;
    --local)
      local_mode=1
      shift
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

repo_root="$(git -C "$PWD" rev-parse --show-toplevel)"
# shellcheck disable=SC1091
source "${repo_root}/apps/_helpers/secret-domains.sh"
domain="$(resolve_secret_domain "$domain")"
assert_secret_domain_host "$domain" "$host"
cd "$repo_root"

if [[ "$host" == "${SOPS_MACHINE_HOSTNAME:-$(hostname -s)}" ]]; then
  local_mode=1
fi
if [[ "$local_mode" != "1" ]] && ! [ -t 0 ]; then
  echo "Error: no TTY available for sudo on ${host}. Run this command from a real terminal." >&2
  exit 1
fi
if [[ "$local_mode" == "1" ]]; then
  pubkey="$(local_runtime_pubkey)"
else
  pubkey="$(remote_runtime_pubkey "${user}@${host}")"
fi

if [[ -z "$pubkey" ]]; then
  echo "Failed to read age public key for ${host}."
  exit 1
fi

if [[ "$domain" != "main" ]]; then
  SOPS_AGE_KEY_FILE="$(domain_age_identity_file "$domain")"
  export SOPS_AGE_KEY_FILE
fi
if [[ "$domain" == "work" ]]; then
  ensure_work_operator_identity "$SOPS_AGE_KEY_FILE"
fi
local_pubkey="$(resolve_local_pubkey)"
if [[ -z "$local_pubkey" ]]; then
  echo "Failed to resolve local age public key."
  exit 1
fi

secret_host="${host}"

secrets_dir="secrets/${domain}"
secrets_file="${secrets_dir}/${secret_host}.yaml"
template_file="${secrets_dir}/_template.yaml"
sops_yaml=".sops.yaml"

control_plane_pubkey=""
if [[ "$domain" == "main" ]]; then
  control_plane_pubkey="$(resolve_control_plane_pubkey "$sops_yaml" "$local_pubkey" "$domain" || true)"
fi
if [[ "$control_plane_pubkey" == "$pubkey" || "$control_plane_pubkey" == "$local_pubkey" ]]; then
  control_plane_pubkey=""
fi

if [[ "$local_pubkey" == "$pubkey" ]]; then
  local_top_key_line=""
  local_rule_key_line=""
else
  local_top_key_line="  - ${local_pubkey}"
  local_rule_key_line="          - ${local_pubkey}"
fi

if [[ -z "$control_plane_pubkey" ]]; then
  control_top_key_line=""
  control_rule_key_line=""
else
  control_top_key_line="  - ${control_plane_pubkey}"
  control_rule_key_line="          - ${control_plane_pubkey}"
fi

mkdir -p "$secrets_dir"

if [[ ! -f "$sops_yaml" ]]; then
  cat > "$sops_yaml" <<EOF
keys:
  - ${pubkey}
${local_top_key_line}
${control_top_key_line}
creation_rules:
  - path_regex: secrets/${domain}/${secret_host}\\.yaml\$
    key_groups:
      - age:
          - ${pubkey}
${local_rule_key_line}
${control_rule_key_line}
EOF
  echo "Created $sops_yaml."
else
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

  if ! (command -v rg >/dev/null 2>&1 && rg -q "secrets/${domain}/${secret_host}\\\\.yaml" "$sops_yaml") \
    && ! grep -q "secrets/${domain}/${secret_host}\\.yaml" "$sops_yaml"; then
    yq -i ".keys += [\"${pubkey}\",\"${local_pubkey}\"] | .keys |= unique" "$sops_yaml"
    if [[ -n "$control_plane_pubkey" ]]; then
      yq -i ".keys += [\"${control_plane_pubkey}\"] | .keys |= unique" "$sops_yaml"
    fi
    yq -i ".creation_rules += [{\"path_regex\":\"secrets/${domain}/${secret_host}\\\\.yaml$\",\"key_groups\":[{\"age\":[\"${pubkey}\",\"${local_pubkey}\"]}]}]" "$sops_yaml"
    if [[ -n "$control_plane_pubkey" ]]; then
      yq -i "(.creation_rules[] | select(.path_regex == \"secrets/${domain}/${secret_host}\\\\.yaml$\") | .key_groups[]?.age) += [\"${control_plane_pubkey}\"]" "$sops_yaml"
      yq -i "(.creation_rules[] | select(.path_regex == \"secrets/${domain}/${secret_host}\\\\.yaml$\") | .key_groups[]?.age) |= unique" "$sops_yaml"
    fi
    echo "Updated $sops_yaml."
  else
    yq -i ".keys += [\"${pubkey}\",\"${local_pubkey}\"] | .keys |= unique" "$sops_yaml"
    if [[ -n "$control_plane_pubkey" ]]; then
      yq -i ".keys += [\"${control_plane_pubkey}\"] | .keys |= unique" "$sops_yaml"
    fi
    yq -i "(.creation_rules[] | select(.path_regex == \"secrets/${domain}/${secret_host}\\\\.yaml$\") | .key_groups[]?.age) += [\"${pubkey}\",\"${local_pubkey}\"]" "$sops_yaml"
    yq -i "(.creation_rules[] | select(.path_regex == \"secrets/${domain}/${secret_host}\\\\.yaml$\") | .key_groups[]?.age) |= unique" "$sops_yaml"
    if [[ -n "$control_plane_pubkey" ]]; then
      yq -i "(.creation_rules[] | select(.path_regex == \"secrets/${domain}/${secret_host}\\\\.yaml$\") | .key_groups[]?.age) += [\"${control_plane_pubkey}\"]" "$sops_yaml"
      yq -i "(.creation_rules[] | select(.path_regex == \"secrets/${domain}/${secret_host}\\\\.yaml$\") | .key_groups[]?.age) |= unique" "$sops_yaml"
    fi
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
