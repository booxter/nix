#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="${VM_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
FLAKE_REF="path:${REPO_ROOT}"

flake_json() {
  nix eval --impure --json --expr "
    let
      f = builtins.getFlake \"${REPO_ROOT}\";
      names = builtins.attrNames f.nixosConfigurations;
    in
    {
      nixosConfigurations = builtins.listToAttrs (
        map (name: {
          inherit name;
          value = null;
        }) names
      );
    }
  "
}

list_target_hosts_from_flake() {
  local flake_json_data="$1"
  printf '%s\n' "${flake_json_data}" \
    | jq -r '
        .nixosConfigurations as $cfgs
        | [ $cfgs | keys[] | select(test("^local-.*vm$")) | capture("^local-(?<host>.*)vm$").host ]
        | unique[]
      ' \
    | sort -u
}

resolve_target_config_from_flake() {
  local target_host="$1"
  local flake_json_data="$2"
  printf '%s\n' "${flake_json_data}" \
    | jq -r --arg host "$target_host" '
        .nixosConfigurations as $cfgs
        | if ($cfgs | has("local-\($host)vm")) then
            "local-\($host)vm"
          else
            empty
          end
      '
}

usage() {
  local flake_json_data
  if flake_json_data="$(flake_json)"; then
    usage_from_flake "${flake_json_data}"
  else
    echo "Failed to evaluate flake for VM target discovery: ${FLAKE_REF}" >&2
    return 1
  fi
}

usage_from_flake() {
  local flake_json_data="$1"
  cat <<'EOF'
Usage: vm [--gui] <target-host>
Example: vm builder1
Example: vm --gui frame

Available target hosts (resolved via local-<host>vm):
EOF
  list_target_hosts_from_flake "${flake_json_data}" | sed 's/^/  /'
}

main() {
  local gui=false
  local target_host=""

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --help)
        usage || exit 1
        exit 0
        ;;
      --gui)
        gui=true
        ;;
      -*)
        echo "Unknown option: $1" >&2
        echo >&2
        usage >&2
        exit 1
        ;;
      *)
        if [ -n "$target_host" ]; then
          usage >&2
          exit 1
        fi
        target_host="$1"
        ;;
    esac
    shift
  done

  if [ -z "$target_host" ]; then
    usage >&2
    exit 1
  fi

  local flake_json_data
  if ! flake_json_data="$(flake_json)"; then
    echo "Failed to evaluate flake for VM target discovery: ${FLAKE_REF}" >&2
    exit 1
  fi

  local target_config
  target_config="$(resolve_target_config_from_flake "$target_host" "${flake_json_data}")"
  if [ -z "$target_config" ]; then
    echo "Unknown target host: $target_host" >&2
    echo >&2
    usage_from_flake "${flake_json_data}" >&2
    exit 1
  fi

  if [ "$gui" = true ]; then
    export VM_GUI_REPO_ROOT="${REPO_ROOT}"
    export VM_GUI_TARGET_CONFIG="${target_config}"
    exec nix run --impure --expr '
      let
        f = builtins.getFlake (builtins.getEnv "VM_GUI_REPO_ROOT");
        lib = f.inputs.nixpkgs.lib;
        targetConfig = builtins.getEnv "VM_GUI_TARGET_CONFIG";
        cfg = (builtins.getAttr targetConfig f.nixosConfigurations).extendModules {
          modules = [
            {
              virtualisation.vmVariant.virtualisation.graphics = lib.mkForce true;
            }
          ];
        };
      in
      cfg.config.system.build.vm
    ' -L --show-trace
  fi

  exec nix run "${REPO_ROOT}#nixosConfigurations.${target_config}.config.system.build.vm" -L --show-trace
}

main "$@"
