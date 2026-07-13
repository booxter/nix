#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: age-recipient.sh IDENTITY_FILE" >&2
  exit 2
fi

identity_file="$1"
if [[ ! -f "$identity_file" ]]; then
  echo "Age identity file not found: $identity_file" >&2
  exit 1
fi

identity_type="$(sed -n \
  -e '/^[[:space:]]*#/d' \
  -e '/^[[:space:]]*$/d' \
  -e 's/^[[:space:]]*\([^[:space:]]*\).*$/\1/p' \
  "$identity_file" | sed -n '1p')"

metadata_recipient() {
  local recipient_prefix="$1"
  sed -nE \
    "s/^#[^:]*:[[:space:]]*(${recipient_prefix}[0-9a-z]+)[[:space:]]*$/\\1/p" \
    "$identity_file" | sort -u
}

case "$identity_type" in
  AGE-SECRET-KEY-*)
    if ! command -v age-keygen >/dev/null 2>&1; then
      echo "age-keygen is required to derive a native age recipient." >&2
      exit 1
    fi
    age-keygen -y "$identity_file"
    ;;
  AGE-PLUGIN-SE-*)
    recipient="$(metadata_recipient age1se1)"
    if [[ "$recipient" == *$'\n'* ]]; then
      echo "Secure Enclave age identity contains multiple recipient metadata lines: $identity_file" >&2
      exit 1
    fi
    if [[ -n "$recipient" ]]; then
      printf '%s\n' "$recipient"
    else
      if ! command -v age-plugin-se >/dev/null 2>&1; then
        echo "age-plugin-se is required to derive a Secure Enclave age recipient." >&2
        exit 1
      fi
      age-plugin-se recipients -i "$identity_file"
    fi
    ;;
  AGE-PLUGIN-YUBIKEY-*)
    # age-plugin-yubikey identity files include their recipient as metadata.
    # Read that exact pairing instead of enumerating attached YubiKeys, which
    # becomes ambiguous when several compatible keys or slots are present.
    recipient="$(metadata_recipient age1yubikey1)"
    if [[ -z "$recipient" || "$recipient" == *$'\n'* ]]; then
      echo "YubiKey age identity must contain exactly one recipient metadata line: $identity_file" >&2
      exit 1
    fi
    printf '%s\n' "$recipient"
    ;;
  *)
    echo "Unsupported age identity type in: $identity_file" >&2
    exit 1
    ;;
esac
