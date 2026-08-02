#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: git-send-email-store-password

Read an SMTP password from stdin and store it in macOS Keychain for the
sendemail.smtpServer, sendemail.smtpServerPort, and sendemail.smtpUser values
in the effective Git configuration.
EOF
}

if [[ $# -gt 0 ]]; then
  if [[ $# -eq 1 && ( "$1" == "-h" || "$1" == "--help" ) ]]; then
    usage
    exit 0
  fi

  usage >&2
  exit 1
fi

if [[ -t 0 ]]; then
  echo "Refusing to read an SMTP password from the terminal; pipe it on stdin." >&2
  exit 1
fi

smtp_server="$(git config --get sendemail.smtpserver || true)"
smtp_server_port="$(git config --get sendemail.smtpserverport || true)"
smtp_user="$(git config --get sendemail.smtpuser || true)"

if [[ -z "$smtp_server" ]]; then
  echo "sendemail.smtpServer is not configured." >&2
  exit 1
fi

if [[ -z "$smtp_user" ]]; then
  echo "sendemail.smtpUser is not configured." >&2
  exit 1
fi

smtp_host="$smtp_server"
if [[ -n "$smtp_server_port" ]]; then
  smtp_host+=":$smtp_server_port"
fi

smtp_password="$(cat)"
if [[ -z "$smtp_password" ]]; then
  echo "Refusing to store an empty SMTP password." >&2
  exit 1
fi

if [[ "$smtp_password" == *$'\n'* || "$smtp_password" == *$'\r'* ]]; then
  echo "The SMTP password must be a single line." >&2
  exit 1
fi

{
  printf 'protocol=smtp\n'
  printf 'host=%s\n' "$smtp_host"
  printf 'username=%s\n' "$smtp_user"
  printf 'password=%s\n\n' "$smtp_password"
} | git \
  -c credential.helper= \
  -c credential.helper=osxkeychain \
  credential approve

unset smtp_password
printf 'Stored the SMTP credential for %s at %s in Keychain.\n' \
  "$smtp_user" "$smtp_host"
