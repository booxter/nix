#!/usr/bin/env bash
set -euo pipefail

PROMPT="${1:-OpenSSH authentication}"

if [ "${SSH_ASKPASS_PROMPT:-}" = "confirm" ]; then
  exec /usr/bin/osascript - "$PROMPT" <<'APPLESCRIPT'
on run argv
  set promptText to item 1 of argv
  display dialog promptText buttons {"No", "Yes"} default button "Yes" cancel button "No" with title "OpenSSH authentication"
  return "yes"
end run
APPLESCRIPT
fi

if [ "${SSHT_ASKPASS_VISIBLE:-}" = "1" ]; then
  exec /usr/bin/osascript - "$PROMPT" <<'APPLESCRIPT'
on run argv
  set promptText to item 1 of argv
  set response to display dialog promptText default answer "" buttons {"Cancel", "OK"} default button "OK" cancel button "Cancel" with title "OpenSSH authentication"
  return text returned of response
end run
APPLESCRIPT
fi

exec /usr/bin/osascript - "$PROMPT" <<'APPLESCRIPT'
on run argv
  set promptText to item 1 of argv
  set response to display dialog promptText default answer "" with hidden answer buttons {"Cancel", "OK"} default button "OK" cancel button "Cancel" with title "OpenSSH authentication"
  return text returned of response
end run
APPLESCRIPT
