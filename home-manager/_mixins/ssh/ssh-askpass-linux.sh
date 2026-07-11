#!/usr/bin/env bash
set -euo pipefail

PROMPT="${1:-OpenSSH authentication}"

case "$PROMPT" in
  "User presence confirmed"*)
    exit 0
    ;;
esac

if [ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
  if ! { exec 3<>/dev/tty; } 2>/dev/null; then
    exit 1
  fi

  case "$PROMPT" in
    "Confirm user presence for key "*)
      printf '%s [press Enter] ' "$PROMPT" >&3
      IFS= read -r _ <&3
      exit 0
      ;;
  esac

  if [ "${SSH_ASKPASS_PROMPT:-}" = "confirm" ]; then
    printf '%s [y/N] ' "$PROMPT" >&3
    IFS= read -r answer <&3 || exit 1

    case "$answer" in
      y | Y | yes | YES | Yes)
        printf '%s\n' yes
        exit 0
        ;;
    esac

    exit 1
  fi

  case "$PROMPT" in
    "TTL for SSH ticket"*)
      printf '%s: ' "$PROMPT" >&3
      IFS= read -r answer <&3 || exit 1
      printf '%s\n' "$answer"
      exit 0
      ;;
  esac

  printf '%s' "$PROMPT" >&3
  saved_tty="$(stty -g <&3)" || exit 1
  trap 'stty "$saved_tty" <&3 2>/dev/null' EXIT HUP INT TERM
  stty -echo <&3
  IFS= read -r answer <&3 || exit 1
  printf '\n' >&3
  printf '%s\n' "$answer"
  exit 0
fi

case "$PROMPT" in
  "Confirm user presence for key "*)
    exec zenity --info \
      --title "OpenSSH security key" \
      --width 460 \
      --ok-label "Dismiss" \
      --text "$PROMPT"
    ;;
esac

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
