#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/sops-pass.sh HOST USER
  scripts/sops-pass.sh --help

Hash a login password with mkpasswd and store it in secrets/HOST.yaml.
USER must be either root or ihrachyshka.
EOF
}

resolve_repo_root() {
  if git -C "$PWD" rev-parse --show-toplevel >/dev/null 2>&1; then
    git -C "$PWD" rev-parse --show-toplevel
    return
  fi
  local script_dir
  script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
  cd -- "${script_dir}/.." && pwd
}

read_passwords() {
  local password_fd="${SOPS_PASS_PASSWORD_FD:-}"

  if [[ -n "$password_fd" ]]; then
    read -r password <&"$password_fd"
    read -r confirm <&"$password_fd"
    return
  fi

  if [[ ! -t 0 ]]; then
    echo "Error: no TTY available for password input." >&2
    exit 1
  fi

  read -r -s -p "Password for ${user}@${host}: " password
  printf '\n'
  read -r -s -p "Confirm password for ${user}@${host}: " confirm
  printf '\n'
}

host=""
user=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      if [[ -z "$host" ]]; then
        host="$1"
      elif [[ -z "$user" ]]; then
        user="$1"
      else
        usage >&2
        exit 1
      fi
      shift
      ;;
  esac
done

if [[ -z "$host" || -z "$user" ]]; then
  usage >&2
  exit 1
fi

case "$user" in
  root | ihrachyshka) ;;
  *)
    echo "Unsupported user: $user" >&2
    echo "Expected one of: root, ihrachyshka" >&2
    exit 1
    ;;
esac

repo_root="$(resolve_repo_root)"
secret="${repo_root}/secrets/${host}.yaml"

if [[ ! -f "$secret" ]]; then
  echo "Secret not found: $secret" >&2
  echo "Bootstrap it first with: nix run .#sops-bootstrap -- ${host}" >&2
  exit 1
fi

plain="$(mktemp)"
merged_json="$(mktemp)"
encrypted="$(mktemp)"
hash_file="$(mktemp)"
trap 'rm -f "${plain:-}" "${merged_json:-}" "${encrypted:-}" "${hash_file:-}"' EXIT

password=""
confirm=""
read_passwords

if [[ -z "$password" ]]; then
  echo "Password must not be empty." >&2
  exit 1
fi

if [[ "$password" != "$confirm" ]]; then
  echo "Passwords do not match." >&2
  exit 1
fi

hash="$(printf '%s\n' "$password" | mkpasswd --method=sha-512 --stdin)"
password=""
confirm=""

sha512_prefix="\$6\$"
if [[ ! "$hash" == "${sha512_prefix}"* ]]; then
  echo "mkpasswd returned an unexpected hash format." >&2
  exit 1
fi

printf '%s' "$hash" > "$hash_file"
hash=""

sops --decrypt "$secret" > "$plain"
yq -o=json '.' "$plain" \
  | jq \
    --arg user "$user" \
    --rawfile hash "$hash_file" \
    'setpath(["users", $user, "hashedPassword"]; $hash)' > "$merged_json"

sops --encrypt --filename-override "$secret" --input-type json --output-type yaml "$merged_json" > "$encrypted"
mv "$encrypted" "$secret"

echo "Updated users/${user}/hashedPassword in ${secret}."
