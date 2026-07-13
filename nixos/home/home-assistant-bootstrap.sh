#!/usr/bin/env bash

set -euo pipefail

# Home Assistant blocks normal authentication until its mandatory onboarding
# steps are complete. This script finishes those steps through Home Assistant's
# supported HTTP API so the first administrator does not need to use the UI.
#
# The user step is special: its first successful request creates Home
# Assistant's owner account. If a prior run created that account but stopped
# before finishing onboarding, the recovery path logs in as the same owner and
# resumes the remaining steps.

base_url=@baseUrl@
client_id=@clientId@
owner_display_name=@ownerDisplayName@
owner_language=@ownerLanguage@
owner_username=@ownerUsername@
password_file=@passwordFile@
work_dir="$(@coreutils@/bin/mktemp -d)"
trap '@coreutils@/bin/rm -rf "$work_dir"' EXIT

# Wait for Home Assistant to expose its onboarding status, then retain this
# snapshot so each still-pending step is submitted at most once during the run.
until @curl@/bin/curl --silent --show-error --fail \
  "$base_url/api/onboarding" > "$work_dir/status.json"; do
  @coreutils@/bin/sleep 2
done

step_done() {
  @jq@/bin/jq --exit-status --arg step "$1" \
    'any(.[]; .step == $step and .done == true)' \
    "$work_dir/status.json" >/dev/null
}

if @jq@/bin/jq --exit-status \
  'all(.[]; .done == true)' "$work_dir/status.json" >/dev/null; then
  exit 0
fi

if ! step_done user; then
  # The first onboarding request creates the configured fleet user as Home
  # Assistant's owner and returns an authorization code for the next steps.
  @jq@/bin/jq --null-input \
    --arg client_id "$client_id" \
    --arg language "$owner_language" \
    --arg name "$owner_display_name" \
    --arg username "$owner_username" \
    --rawfile password "$password_file" \
    '{
      name: $name,
      username: $username,
      password: ($password | rtrimstr("\n")),
      client_id: $client_id,
      language: $language
    }' > "$work_dir/user.json"

  @curl@/bin/curl --silent --show-error --fail \
    --header 'Content-Type: application/json' \
    --data @"$work_dir/user.json" \
    "$base_url/api/onboarding/users" > "$work_dir/user-response.json"
  auth_code="$(@jq@/bin/jq --exit-status --raw-output \
    '.auth_code' "$work_dir/user-response.json")"
else
  # Recover an interrupted bootstrap by authenticating the already-created
  # owner through Home Assistant's local authentication flow.
  @jq@/bin/jq --null-input \
    --arg client_id "$client_id" \
    '{
      client_id: $client_id,
      handler: ["homeassistant", null],
      redirect_uri: $client_id
    }' > "$work_dir/login-flow.json"
  @curl@/bin/curl --silent --show-error --fail \
    --header 'Content-Type: application/json' \
    --data @"$work_dir/login-flow.json" \
    "$base_url/auth/login_flow" > "$work_dir/login-flow-response.json"
  flow_id="$(@jq@/bin/jq --exit-status --raw-output \
    '.flow_id' "$work_dir/login-flow-response.json")"

  @jq@/bin/jq --null-input \
    --arg client_id "$client_id" \
    --arg username "$owner_username" \
    --rawfile password "$password_file" \
    '{
      client_id: $client_id,
      username: $username,
      password: ($password | rtrimstr("\n"))
    }' > "$work_dir/login.json"
  @curl@/bin/curl --silent --show-error --fail \
    --header 'Content-Type: application/json' \
    --data @"$work_dir/login.json" \
    "$base_url/auth/login_flow/$flow_id" > "$work_dir/login-response.json"
  auth_code="$(@jq@/bin/jq --exit-status --raw-output \
    '.result' "$work_dir/login-response.json")"
fi

# Exchange the short-lived authorization code for the token required by the
# remaining authenticated onboarding endpoints.
@curl@/bin/curl --silent --show-error --fail \
  --data-urlencode "client_id=$client_id" \
  --data-urlencode 'grant_type=authorization_code' \
  --data-urlencode "code=$auth_code" \
  "$base_url/auth/token" > "$work_dir/token.json"
access_token="$(@jq@/bin/jq --exit-status --raw-output \
  '.access_token' "$work_dir/token.json")"

complete_step() {
  step="$1"
  payload="$2"
  if ! step_done "$step"; then
    @curl@/bin/curl --silent --show-error --fail \
      --header "Authorization: Bearer $access_token" \
      --header 'Content-Type: application/json' \
      --data "$payload" \
      "$base_url/api/onboarding/$step" >/dev/null
  fi
}

# These steps establish the declarative core configuration, record the
# analytics onboarding choice, and finish the browser redirect handshake.
complete_step core_config '{}'
complete_step analytics '{}'
complete_step integration "$(@jq@/bin/jq --compact-output --null-input \
  --arg client_id "$client_id" \
  '{client_id: $client_id, redirect_uri: $client_id}')"
