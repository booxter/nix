#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Convert arguments to a Nix list string, e.g. '[ "host1" "host2" ]'
# If no arguments, use null to indicate "all hosts"
if [[ $# -gt 0 ]]; then
  HOSTS_NIX="[ $(printf '"%s" ' "$@")]"
else
  HOSTS_NIX="null"
fi

nix eval --impure --json --expr "
  let
    hostInventory = import \"${REPO_ROOT}/lib/inventory.nix\" {
      # get-hosts only needs VM naming and isWork flags. Keep this import cheap
      # by stubbing the one lib function inventory.nix currently references for the
      # unrelated UPS-name helper.
      lib = {
        strings.toUpper = s: s;
      };
    };
    hostWorkMap = {
      darwin = builtins.mapAttrs (_: cfg: cfg.isWork or false) hostInventory.darwinHosts;
      nixos = builtins.foldl' (
        acc: spec:
        let
          isWork = spec.isWork or false;
          configName = hostInventory.toNixosConfigName spec;
          displayName = if spec.type == \"vm\" then spec.name else configName;
        in
        acc
        // {
          \${displayName} = isWork;
        }
      ) { } hostInventory.nixosHostSpecs;
    };
    nixosAliases = builtins.foldl' (
      acc: spec:
      let
        configName = hostInventory.toNixosConfigName spec;
        displayName = if spec.type == \"vm\" then spec.name else configName;
      in
      acc
      // {
        \${displayName} = displayName;
      }
      // (
        if configName == displayName then
          { }
        else
          {
            \${configName} = displayName;
          }
      )
    ) { } hostInventory.nixosHostSpecs;
    darwinAliases = builtins.mapAttrs (name: _: name) hostInventory.darwinHosts;
    requestedHosts = ${HOSTS_NIX};
    filterNames = attrs: aliases: requestedList:
      let
        allNames = builtins.attrNames attrs;
        namesToUse =
          if requestedList == null
          then allNames
          else builtins.filter (name: builtins.elem name allNames) (
            map (name: aliases.\${name} or name) requestedList
          );
      in
      builtins.listToAttrs (
        map
          (name: {
            inherit name;
            value = builtins.getAttr name attrs;
          })
          namesToUse
      );
  in
  {
    nixos = filterNames hostWorkMap.nixos nixosAliases requestedHosts;
    darwin = filterNames hostWorkMap.darwin darwinAliases requestedHosts;
  }
"
