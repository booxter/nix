#!/usr/bin/env bash
set -euo pipefail

PROMPT="${1:-OpenSSH authentication}"

if [ "${SSH_ASKPASS_PROMPT:-}" = "confirm" ]; then
  if zenity --question \
    --title "OpenSSH authentication" \
    --width 460 \
    --ok-label "Yes" \
    --cancel-label "No" \
    --text "$PROMPT"; then
    printf '%s\n' yes
    exit 0
  fi

  exit 1
fi

entry_args=(
  --entry
  --title "OpenSSH authentication"
  --text "$PROMPT"
)

case "$PROMPT" in
  "TTL for SSH ticket"*)
    ;;
  *)
    entry_args+=(--hide-text)
    ;;
esac

answer="$(zenity "${entry_args[@]}")" || exit 1
printf '%s\n' "$answer"
