#!/usr/bin/env bash
set -euo pipefail

"${CI_PREPARE_VM_KEYCHAIN:?Deploy the updated mmini runner configuration first}"

state="$(mktemp -d "$RUNNER_TEMP/mair-vm.XXXXXX")"
launcher=

# The EXIT trap calls this function.
# shellcheck disable=SC2329
cleanup() {
  if [[ -n "$launcher" ]]; then
    kill -TERM "$launcher" 2>/dev/null || true
    wait "$launcher" || true
  fi

  rm -rf -- "$state"
}

trap 'cleanup' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

cd "$state"
mkfifo launcher-output
nix run --print-build-logs "$GITHUB_WORKSPACE#darwinConfigurations.mair.config.system.build.ciVm" >launcher-output &
launcher=$!

while IFS= read -r line; do
  printf '%s\n' "$line"
  # The launcher checks /run/current-system before reporting readiness.
  if [[ "$line" == "Ready: guest configuration activated" ]]; then
    exit 0
  fi
done <launcher-output

wait "$launcher"
echo "VM exited before verifying activation." >&2
exit 1
