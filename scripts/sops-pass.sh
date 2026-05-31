#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/sops-pass.sh [--gen] HOST USER
  scripts/sops-pass.sh --help

Hash a login password with mkpasswd and store it in secrets/HOST.yaml.
USER must be root, ihrachyshka, or both.

By default, insert the password into pass first, under host/CANONICAL_HOST/USER,
then hash the stored password. With --gen, generate the pass entry instead.
Proxmox VM names are canonicalized, so both gw and prox-gwvm use
host/gw/USER and update secrets/prox-gwvm.yaml.

Environment:
  SOPS_PASS_PREFIX            pass prefix for entries (default: host)
  SOPS_PASS_GENERATE_LENGTH   generated password length (default: 32)
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

pass_machine_name() {
  local machine="$1"
  if [[ "${machine}" == prox-*vm ]]; then
    machine="${machine#prox-}"
    machine="${machine%vm}"
  fi
  printf '%s\n' "${machine}"
}

resolve_secret_host() {
  local machine="$1"
  if [[ -f "${repo_root}/secrets/${machine}.yaml" ]]; then
    printf '%s\n' "${machine}"
    return
  fi

  local prox_machine="prox-${machine}vm"
  if [[ -f "${repo_root}/secrets/${prox_machine}.yaml" ]]; then
    printf '%s\n' "${prox_machine}"
    return
  fi

  printf '%s\n' "${machine}"
}

load_password_from_pass() {
  local pass_prefix="${SOPS_PASS_PREFIX:-host}"
  local password_length="${SOPS_PASS_GENERATE_LENGTH:-32}"
  local pass_host
  pass_host="$(pass_machine_name "${host}")"

  local source_user="$user"
  if [[ "$user" == "both" ]]; then
    source_user="root"
  fi
  pass_entry="${pass_prefix}/${pass_host}/${source_user}"

  if [[ "${generate_password}" == "1" ]]; then
    pass generate --force "${pass_entry}" "${password_length}" >/dev/null
    pass_action="Generated"
  else
    pass insert "${pass_entry}"
    pass_action="Inserted"
  fi

  read -r password < <(pass show "${pass_entry}")

  if [[ "$user" == "both" ]]; then
    pass_extra_entry="${pass_prefix}/${pass_host}/ihrachyshka"
    printf '%s\n' "$password" | pass insert --multiline --force "${pass_extra_entry}" >/dev/null
  fi
}

host=""
user=""
generate_password=0
pass_entry=""
pass_extra_entry=""
pass_action=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --gen)
      generate_password=1
      shift
      ;;
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
  root | ihrachyshka | both) ;;
  *)
    echo "Unsupported user: $user" >&2
    echo "Expected one of: root, ihrachyshka, both" >&2
    exit 1
    ;;
esac

repo_root="$(resolve_repo_root)"
secret_host="$(resolve_secret_host "${host}")"
secret="${repo_root}/secrets/${secret_host}.yaml"

if [[ ! -f "$secret" ]]; then
  echo "Secret not found for host ${host}: ${secret}" >&2
  echo "Bootstrap it first with: nix run .#sops-bootstrap -- ${secret_host}" >&2
  exit 1
fi

plain="$(mktemp)"
merged_json="$(mktemp)"
encrypted="$(mktemp)"
hash_file="$(mktemp)"
trap 'rm -f "${plain:-}" "${merged_json:-}" "${encrypted:-}" "${hash_file:-}"' EXIT

password=""
load_password_from_pass

if [[ -z "$password" ]]; then
  echo "Stored password must not be empty: ${pass_entry}" >&2
  exit 1
fi

hash="$(printf '%s\n' "$password" | mkpasswd --method=sha-512 --stdin)"
password=""

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
    '
      if $user == "both" then
        setpath(["users", "root", "hashedPassword"]; $hash)
        | setpath(["users", "ihrachyshka", "hashedPassword"]; $hash)
      else
        setpath(["users", $user, "hashedPassword"]; $hash)
      end
    ' > "$merged_json"

sops --encrypt --filename-override "$secret" --input-type json --output-type yaml "$merged_json" > "$encrypted"
mv "$encrypted" "$secret"

if [[ "${user}" == "both" ]]; then
  echo "Updated users/root/hashedPassword and users/ihrachyshka/hashedPassword in ${secret}."
else
  echo "Updated users/${user}/hashedPassword in ${secret}."
fi
if [[ -n "${pass_entry}" ]]; then
  if [[ -n "${pass_extra_entry}" ]]; then
    echo "${pass_action} ${pass_entry} and ${pass_extra_entry}."
  else
    echo "${pass_action} ${pass_entry}."
  fi
fi
