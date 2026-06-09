#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="${VM_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
FLAKE_REF="path:${REPO_ROOT}"

flake_json() {
  nix eval --impure --json --expr "
    let
      f = builtins.getFlake \"${REPO_ROOT}\";
      names = builtins.attrNames f.nixosConfigurations;
      cfgs = builtins.listToAttrs (
        map (name: {
          inherit name;
          value = null;
        }) names
      );
      hostInventory = import \"${REPO_ROOT}/lib/inventory.nix\" {
        lib = f.inputs.nixpkgs.lib;
      };
      inventoryTargets = builtins.filter (target: builtins.hasAttr target.configName cfgs) (
        map (
          spec:
          let
            configName = hostInventory.toNixosConfigName spec;
            displayName = if spec.type == \"vm\" then spec.name else configName;
          in
          {
            inherit configName displayName;
          }
        ) hostInventory.nixosHostSpecs
      );
      displayAliases = builtins.listToAttrs (
        map (target: {
          name = target.displayName;
          value = target.configName;
        }) inventoryTargets
      );
    in
    {
      nixosConfigurations = cfgs;
      targetAliases = displayAliases;
      targetDisplayNames = builtins.attrNames displayAliases;
    }
  "
}

list_target_hosts_from_flake() {
  local flake_json_data="$1"
  printf '%s\n' "${flake_json_data}" \
    | jq -r '
        if (.targetDisplayNames? | type) == "array" then
          .targetDisplayNames
        else
          .nixosConfigurations as $cfgs
          | [
              $cfgs
              | keys[]
              | if test("^prox-.*vm$") then
                  capture("^prox-(?<host>.*)vm$").host
                else
                  .
                end
            ]
        end
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
        | (.targetAliases // {}) as $aliases
        | if ($aliases | has($host)) then
            $aliases[$host]
          elif (($host | test("^prox-.*vm$") | not) and ($cfgs | has($host))) then
            $host
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

Available target hosts:
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

  export VM_REPO_ROOT="${REPO_ROOT}"
  export VM_TARGET_CONFIG="${target_config}"
  if [ "$gui" = true ]; then
    export VM_GUI=1
  else
    export VM_GUI=0
  fi

  exec nix run --impure --expr '
    let
      f = builtins.getFlake (builtins.getEnv "VM_REPO_ROOT");
      lib = f.inputs.nixpkgs.lib;
      targetConfig = builtins.getEnv "VM_TARGET_CONFIG";
      hostPkgs = import f.inputs.nixpkgs { system = builtins.currentSystem; };
      gui = builtins.getEnv "VM_GUI" == "1";
      cfg = (builtins.getAttr targetConfig f.nixosConfigurations).extendModules {
        modules = [
          {
            virtualisation.vmVariant.virtualisation.host.pkgs = lib.mkForce hostPkgs;
          }
        ]
        ++ lib.optional gui {
          virtualisation.vmVariant.virtualisation.graphics = lib.mkForce true;
        };
      };
    in
    cfg.config.system.build.vm
  ' -L --show-trace
}

main "$@"
