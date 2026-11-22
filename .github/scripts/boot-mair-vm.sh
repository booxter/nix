#!/usr/bin/env bash
set -euo pipefail

"${CI_PREPARE_VM_KEYCHAIN:?Deploy the updated mmini runner configuration first}"

state="$(mktemp -d "$RUNNER_TEMP/mair-vm.XXXXXX")"
child_pid=

# The EXIT trap calls this function.
# shellcheck disable=SC2329
cleanup() {
  if [[ -n "$child_pid" ]]; then
    kill -TERM "$child_pid" 2>/dev/null || true
    wait "$child_pid" || true
  fi

  rm -rf -- "$state"
}

trap 'cleanup' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

cd "$state"
vm="$GITHUB_WORKSPACE#darwinConfigurations.mair.config.system.build"

# Keep the restore image across jobs. Replacing this root releases the previous image.
if [[ -n "${CI_MAIR_VM_IPSW_ROOT:-}" ]]; then
  nix build --print-build-logs --out-link "$CI_MAIR_VM_IPSW_ROOT" "$vm.ciVmIpsw" &
  child_pid=$!
  wait "$child_pid"
  child_pid=
fi

mkfifo launcher-output
nix run --print-build-logs "$vm.ciVm" >launcher-output &
child_pid=$!

while IFS= read -r line; do
  printf '%s\n' "$line"
  # The launcher checks /run/current-system before reporting readiness.
  if [[ "$line" == "Ready: guest configuration activated" ]]; then
    exit 0
  fi
done <launcher-output

wait "$child_pid"
echo "VM exited before verifying activation." >&2
exit 1
